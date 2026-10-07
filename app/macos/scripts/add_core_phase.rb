#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Configures macos/Runner.xcodeproj for Melsi (idempotent):
#   * adds a "Bundle melsi-core" Run Script phase to Runner that copies
#     core/dist/melsi-core-darwin-universal (scripts/build-core.sh) into
#     Melsi.app/Contents/Resources/melsi-core (warns, never fails, if missing);
#   * fixes RunnerTests bundle id / TEST_HOST after the product rename
#     (PRODUCT_NAME = Melsi lives in Runner/Configs/AppInfo.xcconfig);
#   * sets MACOSX_DEPLOYMENT_TARGET.
#
#   gem install xcodeproj
#   ruby app/macos/scripts/add_core_phase.rb

require 'xcodeproj'

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

MACOS_DIR = File.expand_path('..', __dir__)
PROJECT_PATH = File.join(MACOS_DIR, 'Runner.xcodeproj')
PHASE_NAME = 'Bundle melsi-core'
DEPLOYMENT_TARGET = '12.0' # Flutter's minimum for macOS

SCRIPT = <<~'SH'
  # Copies melsi-core and the pinned Xray-core into Contents/Resources.
  # melsi-core: scripts/build-core.sh. Xray: scripts/fetch-xray.sh.
  DIST="${PROJECT_DIR}/../../core/dist"
  DEST_DIR="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
  mkdir -p "${DEST_DIR}"
  DEST="${DEST_DIR}/melsi-core"
  if [ -f "${DIST}/melsi-core-darwin-universal" ]; then
    cp -f "${DIST}/melsi-core-darwin-universal" "${DEST}"
  elif [ -f "${DIST}/melsi-core-darwin-arm64" ] && [ -f "${DIST}/melsi-core-darwin-amd64" ]; then
    lipo -create "${DIST}/melsi-core-darwin-arm64" "${DIST}/melsi-core-darwin-amd64" -output "${DEST}"
  elif [ -f "${DIST}/melsi-core-darwin-$(uname -m | sed 's/x86_64/amd64/')" ]; then
    cp -f "${DIST}/melsi-core-darwin-$(uname -m | sed 's/x86_64/amd64/')" "${DEST}"
  else
    echo "warning: melsi-core not found in ${DIST} (run scripts/build-core.sh); the app will not be able to connect."
    exit 0
  fi
  chmod 755 "${DEST}"
  xattr -c "${DEST}" 2>/dev/null || true
  XRAY="${DEST_DIR}/xray"
  if [ -f "${DIST}/xray-darwin-universal" ]; then
    cp -f "${DIST}/xray-darwin-universal" "${XRAY}"
  elif [ -f "${DIST}/xray-darwin-arm64" ] && [ -f "${DIST}/xray-darwin-amd64" ]; then
    lipo -create "${DIST}/xray-darwin-arm64" "${DIST}/xray-darwin-amd64" -output "${XRAY}"
  elif [ -f "${DIST}/xray-darwin-$(uname -m | sed 's/x86_64/amd64/')" ]; then
    cp -f "${DIST}/xray-darwin-$(uname -m | sed 's/x86_64/amd64/')" "${XRAY}"
  else
    echo "warning: xray not found in ${DIST} (run scripts/fetch-xray.sh); Xray mode will not start."
  fi
  if [ -f "${XRAY}" ]; then
    chmod 755 "${XRAY}"
    xattr -c "${XRAY}" 2>/dev/null || true
  fi
  if [ -f "${DIST}/XRAY-LICENSE" ]; then
    cp -f "${DIST}/XRAY-LICENSE" "${DEST_DIR}/XRAY-LICENSE"
  fi
  # Sign nested binaries with the app's identity when signing is enabled.
  if [ "${CODE_SIGNING_ALLOWED}" = "YES" ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY}" ]; then
    codesign --force --options runtime --timestamp=none --sign "${EXPANDED_CODE_SIGN_IDENTITY}" "${DEST}" || echo "warning: codesign melsi-core failed"
    if [ -f "${XRAY}" ]; then
      codesign --force --options runtime --timestamp=none --sign "${EXPANDED_CODE_SIGN_IDENTITY}" "${XRAY}" || echo "warning: codesign xray failed"
    fi
  fi
SH

project = Xcodeproj::Project.open(PROJECT_PATH)
runner = project.targets.find { |t| t.name == 'Runner' } or abort('Runner target not found')
tests = project.targets.find { |t| t.name == 'RunnerTests' }

phase = runner.shell_script_build_phases.find { |p| p.name == PHASE_NAME }
phase ||= runner.new_shell_script_build_phase(PHASE_NAME)
phase.shell_path = '/bin/sh'
phase.shell_script = SCRIPT
phase.always_out_of_date = '1'
phase.show_env_vars_in_log = '0'
phase.input_paths = []
phase.output_paths = []

# Place it right after "Copy Bundle Resources" (before Flutter's embed script).
phases = runner.build_phases
phases.delete(phase)
resources = runner.resources_build_phase
index = resources ? phases.index(resources) + 1 : phases.length
phases.insert(index, phase)

project.build_configurations.each do |config|
  config.build_settings['MACOSX_DEPLOYMENT_TARGET'] = DEPLOYMENT_TARGET
end

# Product reference label (actual name comes from PRODUCT_NAME).
runner.product_reference.path = 'Melsi.app' if runner.product_reference

tests&.build_configurations&.each do |config|
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'app.melsi.RunnerTests'
  config.build_settings['TEST_HOST'] = '$(BUILT_PRODUCTS_DIR)/Melsi.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Melsi'
end

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
  puts "  target #{t.name}"
  t.build_phases.each { |p| puts "    - #{p.display_name}" }
end
