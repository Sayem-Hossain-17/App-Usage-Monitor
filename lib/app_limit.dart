class AppLimit {
  final String packageName;
  final String appName;
  final Duration limit;
  final Duration baseUsage;
  final bool isActive;
  final bool notified;

  AppLimit({
    required this.packageName,
    required this.appName,
    required this.limit,
    this.baseUsage = Duration.zero,
    this.isActive = true,
    this.notified = false,
  });
}