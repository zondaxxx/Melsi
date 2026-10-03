#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Adds / updates the "PacketTunnel" Network Extension target in
# ios/Runner.xcodeproj and configures the Runner target for Melsi.
#
# Idempotent: re-running converges to the same project state.
#
#   gem install xcodeproj
#   ruby app/ios/scripts/add_packet_tunnel.rb
#
# The extension statically links Frameworks/Libbox.xcframework (gomobile
# output of libbox + melsicore, produced by scripts/build-libbox.sh). It is
# linked, never embedded. Runner does NOT link libbox.

require 'xcodeproj'

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

IOS_DIR = File.expand_path('..', __dir__)
PROJECT_PATH = File.join(IOS_DIR, 'Runner.xcodeproj')

APP_BUNDLE_ID = 'app.melsi'
EXT_NAME = 'PacketTunnel'
EXT_BUNDLE_ID = 'app.melsi.PacketTunnel'
DEPLOYMENT_TARGET = '15.0'
SWIFT_VERSION = '5.0'

EXT_SOURCES = %w[PacketTunnelProvider.swift MelsiPlatformInterface.swift TunnelConfiguration.swift].freeze
RUNNER_SOURCES = %w[MelsiVpnBridge.swift].freeze

project = Xcodeproj::Project.open(PROJECT_PATH)

def find_or_create_group(parent, name, path)
  parent.children.find { |c| c.isa == 'PBXGroup' && (c.path == path || c.name == name) } ||
    parent.new_group(name, path)
end

def find_or_create_file(group, path, file_type = nil)
  ref = group.files.find { |f| f.path == path }
  ref ||= group.new_reference(path)
  ref.last_known_file_type = file_type if file_type
  ref
end

def ensure_in_phase(phase, file_ref, settings = nil)
  bf = phase.files.find { |f| f.file_ref == file_ref }
  bf ||= phase.add_file_reference(file_ref, true)
  bf.settings = settings if settings
  bf
end

runner = project.targets.find { |t| t.name == 'Runner' } or abort('Runner target not found')
runner_tests = project.targets.find { |t| t.name == 'RunnerTests' }

# ---------------------------------------------------------------------------
# Project-wide deployment target
project.build_configurations.each do |config|
  config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = DEPLOYMENT_TARGET
end

# ---------------------------------------------------------------------------
# Runner
runner_group = project.main_group.children.find { |c| c.isa == 'PBXGroup' && c.path == 'Runner' } or abort('Runner group not found')

RUNNER_SOURCES.each do |name|
  ref = find_or_create_file(runner_group, name, 'sourcecode.swift')
  ensure_in_phase(runner.source_build_phase, ref)
end
find_or_create_file(runner_group, 'Runner.entitlements', 'text.plist.entitlements')

system_frameworks = project.frameworks_group
ne_ref = system_frameworks.files.find { |f| f.path == 'System/Library/Frameworks/NetworkExtension.framework' }
ne_ref ||= system_frameworks.new_reference('System/Library/Frameworks/NetworkExtension.framework', :sdk_root)
ne_ref.name = 'NetworkExtension.framework'
ne_ref.last_known_file_type = 'wrapper.framework'
ensure_in_phase(runner.frameworks_build_phase, ne_ref)

runner.build_configurations.each do |config|
  s = config.build_settings
  s['PRODUCT_BUNDLE_IDENTIFIER'] = APP_BUNDLE_ID
  s['CODE_SIGN_ENTITLEMENTS'] = 'Runner/Runner.entitlements'
  s['IPHONEOS_DEPLOYMENT_TARGET'] = DEPLOYMENT_TARGET
  s['SWIFT_VERSION'] = SWIFT_VERSION
end

runner_tests&.build_configurations&.each do |config|
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = "#{APP_BUNDLE_ID}.RunnerTests"
end

# ---------------------------------------------------------------------------
# PacketTunnel target
ext = project.targets.find { |t| t.name == EXT_NAME }
unless ext
  ext = project.new_target(:app_extension, EXT_NAME, :ios, DEPLOYMENT_TARGET, nil, :swift)
  # new_target adds Foundation.framework; Swift autolinks it anyway, drop it
  # to keep the Frameworks phase minimal.
  ext.frameworks_build_phase.files.dup.each do |bf|
    ref = bf.file_ref
    next unless ref&.path&.end_with?('Foundation.framework')

    bf.remove_from_project
    ref.remove_from_project if ref.build_files.empty?
  end
  ios_group = project.frameworks_group['iOS']
  ios_group.remove_from_project if ios_group && ios_group.children.empty?
end

ext_group = find_or_create_group(project.main_group, EXT_NAME, EXT_NAME)
EXT_SOURCES.each do |name|
  ref = find_or_create_file(ext_group, name, 'sourcecode.swift')
  ensure_in_phase(ext.source_build_phase, ref)
end
find_or_create_file(ext_group, 'Info.plist', 'text.plist.xml')
find_or_create_file(ext_group, "#{EXT_NAME}.entitlements", 'text.plist.entitlements')
xcconfig_ref = find_or_create_file(ext_group, "#{EXT_NAME}.xcconfig", 'text.xcconfig')
rules_ref = find_or_create_file(ext_group, '../../assets/rulesets', 'folder')
rules_ref.name = 'rulesets'
ensure_in_phase(ext.resources_build_phase, rules_ref)
tests = project.targets.find { |target| target.name == 'RunnerTests' }
if tests
  tests_group = find_or_create_group(project.main_group, 'RunnerTests', 'RunnerTests')
  tests_ref = find_or_create_file(tests_group, 'TunnelConfigurationTests.swift', 'sourcecode.swift')
  ensure_in_phase(tests.source_build_phase, tests_ref)
  config_ref = find_or_create_file(ext_group, 'TunnelConfiguration.swift', 'sourcecode.swift')
  ensure_in_phase(tests.source_build_phase, config_ref)
end

# Frameworks: NetworkExtension + Libbox.xcframework (static, link only)
ensure_in_phase(ext.frameworks_build_phase, ne_ref)
# frameworks_group ("Frameworks", no path) -> path is relative to ios/.
libbox_ref = find_or_create_file(system_frameworks, 'Frameworks/Libbox.xcframework', 'wrapper.xcframework')
libbox_ref.name = 'Libbox.xcframework'
libbox_ref.source_tree = '<group>'
ensure_in_phase(ext.frameworks_build_phase, libbox_ref)

# Make sure Libbox is never embedded anywhere.
project.targets.each do |t|
  t.copy_files_build_phases.each do |phase|
    phase.files.dup.each { |bf| bf.remove_from_project if bf.file_ref == libbox_ref }
  end
end

ext.build_configurations.each do |config|
  config.base_configuration_reference = xcconfig_ref
  s = config.build_settings
  s['PRODUCT_NAME'] = '$(TARGET_NAME)'
  s['PRODUCT_BUNDLE_IDENTIFIER'] = EXT_BUNDLE_ID
  s['INFOPLIST_FILE'] = "#{EXT_NAME}/Info.plist"
  s['GENERATE_INFOPLIST_FILE'] = 'NO'
  s['CODE_SIGN_ENTITLEMENTS'] = "#{EXT_NAME}/#{EXT_NAME}.entitlements"
  s['CODE_SIGN_STYLE'] = 'Automatic'
  s['SWIFT_VERSION'] = SWIFT_VERSION
  s['IPHONEOS_DEPLOYMENT_TARGET'] = DEPLOYMENT_TARGET
  s['TARGETED_DEVICE_FAMILY'] = '1,2'
  s['SDKROOT'] = 'iphoneos'
  # Go runtime / sing-box (static libbox) needs libresolv; SystemConfiguration
  # and Security are referenced by Go's darwin net / crypto/x509 code.
  s['OTHER_LDFLAGS'] = ['$(inherited)', '-lresolv', '-framework', 'SystemConfiguration', '-framework', 'Security', '-framework', 'UIKit']
  s['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/Frameworks', '@executable_path/../../Frameworks']
  s['SKIP_INSTALL'] = 'YES'
  s['APPLICATION_EXTENSION_API_ONLY'] = 'YES'
  s['ENABLE_BITCODE'] = 'NO'
  s['CLANG_ENABLE_MODULES'] = 'YES'
  s['MARKETING_VERSION'] = '$(FLUTTER_BUILD_NAME)'
  s['CURRENT_PROJECT_VERSION'] = '$(FLUTTER_BUILD_NUMBER)'
  s['SWIFT_EMIT_LOC_STRINGS'] = 'NO'
  # Go objects are not built with bitcode / dSYM-friendly debug info.
  s['DEBUG_INFORMATION_FORMAT'] = config.name == 'Debug' ? 'dwarf' : 'dwarf-with-dsym'
  s['SWIFT_OPTIMIZATION_LEVEL'] = config.name == 'Debug' ? '-Onone' : '-O'
  s['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = 'DEBUG' if config.name == 'Debug'
end

# Keep project TargetAttributes in sync (nice-to-have for Xcode UI).
attrs = project.root_object.attributes['TargetAttributes'] ||= {}
attrs[ext.uuid] ||= {}
attrs[ext.uuid]['CreatedOnToolsVersion'] ||= '15.0'

# ---------------------------------------------------------------------------
# Embed PacketTunnel.appex into Runner (PlugIns), before "Thin Binary" to
# avoid the Flutter "Cycle inside Runner" build error.
embed_name = 'Embed Foundation Extensions'
embed = runner.copy_files_build_phases.find { |p| p.name == embed_name || p.name == 'Embed App Extensions' }
unless embed
  embed = project.new(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase)
  embed.name = embed_name
  runner.build_phases << embed
end
embed.name = embed_name
embed.symbol_dst_subfolder_spec = :plug_ins
embed.dst_path = ''
embed.run_only_for_deployment_postprocessing = '0'
ensure_in_phase(embed, ext.product_reference, { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] })

phases = runner.build_phases
phases.delete(embed)
thin = phases.find { |p| p.respond_to?(:name) && p.name == 'Thin Binary' }
index = thin ? phases.index(thin) : phases.length
phases.insert(index, embed)

runner.add_dependency(ext) unless runner.dependencies.any? { |d| d.target == ext }

project.save

# xcodeproj abbreviates the XCLocalSwiftPackageReference comment; restore the
# form Xcode / flutter_tools write so diffs stay minimal.
pbxproj = File.join(PROJECT_PATH, 'project.pbxproj')
content = File.read(pbxproj)
fixed = content.gsub(
  '/* XCLocalSwiftPackageReference "FlutterGeneratedPluginSwiftPackage" */',
  '/* XCLocalSwiftPackageReference "Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage" */'
)
File.write(pbxproj, fixed) if fixed != content
puts "OK: #{PROJECT_PATH}"
project.targets.each do |t|
  puts "  target #{t.name} (#{t.product_type})"
  t.build_phases.each { |p| puts "    - #{p.display_name}" }
end
