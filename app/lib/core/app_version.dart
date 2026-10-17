/// Shared by About, diagnostics, backups and subscription requests.
/// CI supplies the release tag (or development commit) via --dart-define.
const kAppVersion = String.fromEnvironment(
  'MELSI_VERSION',
  defaultValue: '1.1.8',
);
