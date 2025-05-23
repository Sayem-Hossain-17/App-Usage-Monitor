import 'dart:async';
//import 'dart:typed_data';
import 'app_limit.dart';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:device_apps/device_apps.dart';
import 'package:app_usage/app_usage.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'database_helper.dart';


const String notificationChannelId = 'usage_limit_channel';
const String notificationChannelName = 'Usage Limit Alerts';
const String notificationChannelDesc = 'Notifies when app usage limit is exceeded';
const int foregroundServiceNotificationId = 888;
const int usageLimitNotificationBaseId = 1000;

Future<void> initializeService() async {
  final service = FlutterBackgroundService();
  final flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    notificationChannelId,
    notificationChannelName,
    description: notificationChannelDesc,
    importance: Importance.max,
  );

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: true,
      isForegroundMode: true,
      notificationChannelId: notificationChannelId,
      initialNotificationTitle: 'App Usage Monitor',
      initialNotificationContent: 'Monitoring app usage...',
      foregroundServiceNotificationId: foregroundServiceNotificationId,
    ),
    iosConfiguration: IosConfiguration(),
  );
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  final dbHelper = DatabaseHelper();
  final notifications = FlutterLocalNotificationsPlugin();

  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  const initSettings = InitializationSettings(android: androidInit);
  await notifications.initialize(initSettings);
  print('[BG Service] Initialized.');

  Timer.periodic(const Duration(minutes: 1), (timer) async {
    print('[BG Service] Tick! Running check...');
    try {
      final Map<String, AppLimit> limits = (await dbHelper.getAllLimits()).cast<String, AppLimit>();
      if (limits.isEmpty) {
        print('[BG Service] No limits set. Skipping check.');
        return;
      }
      print('[BG Service] Limits loaded: ${limits.length}');

      // Check daily limits
      final DateTime end = DateTime.now();
      final DateTime start = DateTime(end.year, end.month, end.day);
      await _checkLimitsForPeriod(limits, notifications, dbHelper, 'Daily', start, end);

      // Check weekly limits (every Sunday)
      if (end.weekday == DateTime.sunday) {
        final DateTime weekStart = end.subtract(const Duration(days: 7));
        await _checkLimitsForPeriod(limits, notifications, dbHelper, 'Weekly', weekStart, end);
      }

      // Check monthly limits (on 1st of each month)
      if (end.day == 1) {
        final DateTime monthStart = end.month == 1
            ? DateTime(end.year - 1, 12, 1)
            : DateTime(end.year, end.month - 1, 1);
        await _checkLimitsForPeriod(limits, notifications, dbHelper, 'Monthly', monthStart, end);
      }
    } catch (e, stacktrace) {
      print('[BG Service] Error during check: $e');
      print(stacktrace);
    }
  });
}

String _formatDuration(Duration duration) {
  if (duration.inDays > 0) {
    return '${duration.inDays}d ${duration.inHours.remainder(24)}h';
  } else if (duration.inHours > 0) {
    return '${duration.inHours}h ${duration.inMinutes.remainder(60)}m';
  } else if (duration.inMinutes > 0) {
    return '${duration.inMinutes}m ${duration.inSeconds.remainder(60)}s';
  } else {
    return '${duration.inSeconds}s';
  }
}

@pragma('vm:entry-point')
Future<void> _checkLimitsForPeriod(
    Map<String, AppLimit> limits,
    FlutterLocalNotificationsPlugin notifications,
    DatabaseHelper dbHelper,
    String period,
    DateTime start,
    DateTime end) async {
  List<AppUsageInfo> usageInfos = await AppUsage().getAppUsage(start, end);
  Map<String, Duration> currentUsageMap = {
    for (var info in usageInfos) info.packageName: info.usage
  };
  print('[BG Service] $period usage stats loaded: ${usageInfos.length}');

  for (final limitEntry in limits.entries) {
    final String pkg = limitEntry.key;
    final AppLimit limitInfo = limitEntry.value;

    final Duration currentUsage = currentUsageMap[pkg] ?? Duration.zero;
    final Duration limitDuration = limitInfo.limit;
    final bool alreadyNotified = limitInfo.notified;

    print('[BG Service] Checking $pkg ($period): Limit=${_formatDuration(limitDuration)}, Current=${_formatDuration(currentUsage)}, Notified=$alreadyNotified');

    if (currentUsage > limitDuration && !alreadyNotified) {
      print('[BG Service] $period Limit EXCEEDED for $pkg!');
      await _showUsageLimitNotification(
        notifications,
        limitInfo.appName,
        pkg,
        currentUsage,
        limitDuration,
        period,
      );
      await dbHelper.updateNotifiedStatus(pkg, true);
    }
  }
}

Future<void> _showUsageLimitNotification(
    FlutterLocalNotificationsPlugin notifications,
    String appName,
    String packageName,
    Duration currentUsage,
    Duration limit,
    String period) async {

  final notificationId = packageName.hashCode + usageLimitNotificationBaseId;

  final AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
    notificationChannelId,
    notificationChannelName,
    channelDescription: notificationChannelDesc,
    importance: Importance.max,
    priority: Priority.high,
    ticker: 'Usage Limit Exceeded for $appName',
    styleInformation: BigTextStyleInformation(
      '$period usage for $appName (${_formatDuration(currentUsage)}) has exceeded the set limit (${_formatDuration(limit)}).',
    ),
  );

  final NotificationDetails platformDetails = NotificationDetails(android: androidDetails);

  print('[BG Service] Showing notification ID $notificationId for $packageName');
  await notifications.show(
    notificationId,
    '$period Usage Limit Exceeded',
    '$appName $period limit reached',
    platformDetails,
  );
}

Future<void> _checkAndRequestUsagePermission() async {
  try {
    AppUsage appUsage = AppUsage();
    DateTime end = DateTime.now();
    DateTime start = end.subtract(const Duration(hours: 1));
    await appUsage.getAppUsage(start, end);
    print("[Main] Usage stats permission likely granted.");
  } catch (e) {
    print("[Main] Usage stats permission likely denied or usage API not available. Error: $e");
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeService();
  await _checkAndRequestUsagePermission();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'App Usage Monitor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4E6AF3),
          brightness: Brightness.light,
        ),
        textTheme: GoogleFonts.poppinsTextTheme(),
        appBarTheme: AppBarTheme(
          centerTitle: true,
          elevation: 0,
          foregroundColor: Colors.white,
          backgroundColor: const Color(0xFF4E6AF3),
          titleTextStyle: GoogleFonts.poppins(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w600,
          ),
        ),
        cardTheme: CardTheme(
          elevation: 4,
          shadowColor: Colors.black.withAlpha(40),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        ),
        floatingActionButtonTheme: FloatingActionButtonThemeData(
          backgroundColor: const Color(0xFF4E6AF3),
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        bottomNavigationBarTheme: const BottomNavigationBarThemeData(
          selectedItemColor: Color(0xFF4E6AF3),
          unselectedItemColor: Colors.grey,
          showUnselectedLabels: true,
          elevation: 8,
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4E6AF3),
          brightness: Brightness.dark,
        ),
        textTheme: GoogleFonts.poppinsTextTheme(ThemeData.dark().textTheme),
        appBarTheme: AppBarTheme(
          centerTitle: true,
          elevation: 0,
          backgroundColor: const Color(0xFF2D3142),
          titleTextStyle: GoogleFonts.poppins(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w600,
          ),
        ),
        cardTheme: CardTheme(
          elevation: 4,
          shadowColor: Colors.black.withAlpha(60),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        ),
        floatingActionButtonTheme: FloatingActionButtonThemeData(
          backgroundColor: const Color(0xFF4E6AF3),
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        bottomNavigationBarTheme: const BottomNavigationBarThemeData(
          selectedItemColor: Color(0xFF4E6AF3),
          unselectedItemColor: Colors.grey,
          showUnselectedLabels: true,
          elevation: 8,
        ),
      ),
      themeMode: ThemeMode.system,
      home: const InstalledAppsScreen(),
    );
  }
}

class InstalledAppsScreen extends StatefulWidget {
  const InstalledAppsScreen({super.key});

  @override
  State<InstalledAppsScreen> createState() => _InstalledAppsScreenState();
}

class _InstalledAppsScreenState extends State<InstalledAppsScreen> with SingleTickerProviderStateMixin {
  bool _sortByUsageDesc = false;
  int _selectedIndex = 0;
  List<AppInfo> _apps = [];
  bool _isLoading = true;
  Map<String, Duration> _usageMap = {};
  Map<String, Duration> _weeklyUsageMap = {};
  Map<String, Duration> _monthlyUsageMap = {};
  Map<String, AppLimit> _limitsMap = {};
  String _searchQuery = '';
  String _chartTimePeriod = 'daily';
  final TextEditingController _searchController = TextEditingController();
  final dbHelper = DatabaseHelper();
  late AnimationController _animController;

  final List<Color> _chartGradientColors = [
    const Color(0xFF4E6AF3),
    const Color(0xFF5038ED),
    const Color(0xFF7B61FF),
  ];

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 400)
    );
    _loadData();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _animController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() { _isLoading = true; });

    try {
      _limitsMap = Map<String, AppLimit>.from(await dbHelper.getAllLimits());
      print("[UI] Limits loaded: ${_limitsMap.length}");

      final apps = await DeviceApps.getInstalledApplications(
        includeAppIcons: true,
        includeSystemApps: true,
        onlyAppsWithLaunchIntent: true,
      );
      print("[UI] Apps loaded: ${apps.length}");

      _usageMap = {};
      _weeklyUsageMap = {};
      _monthlyUsageMap = {};

      try {
        // Daily usage
        DateTime end = DateTime.now();
        DateTime start = DateTime(end.year, end.month, end.day);
        List<AppUsageInfo> infos = await AppUsage().getAppUsage(start, end);
        _usageMap = { for (var info in infos) info.packageName: info.usage };
        print("[UI] Daily usage stats loaded: ${infos.length}");

        // Weekly usage
        DateTime weekStart = end.subtract(const Duration(days: 7));
        List<AppUsageInfo> weeklyInfos = await AppUsage().getAppUsage(weekStart, end);
        _weeklyUsageMap = { for (var info in weeklyInfos) info.packageName: info.usage };
        print("[UI] Weekly usage stats loaded: ${weeklyInfos.length}");

        // Monthly usage
        DateTime monthStart = end.month == 1
            ? DateTime(end.year - 1, 12, 1)
            : DateTime(end.year, end.month - 1, 1);
        List<AppUsageInfo> monthlyInfos = await AppUsage().getAppUsage(monthStart, end);
        _monthlyUsageMap = { for (var info in monthlyInfos) info.packageName: info.usage };
        print("[UI] Monthly usage stats loaded: ${monthlyInfos.length}");
      } catch (e) {
        print("[UI] Error getting usage stats: $e");
        if (mounted) {
          _showSnackBar('Could not get app usage. Please grant Usage Stats permission.');
        }
      }

      final List<AppInfo> appInfoList = [];
      for (final app in apps) {
        if (app is ApplicationWithIcon) {
          appInfoList.add(
            AppInfo(
              app: app,
              installDate: null,
            ),
          );
        }
      }
      appInfoList.sort((a, b) => a.app.appName.toLowerCase().compareTo(b.app.appName.toLowerCase()));

      setState(() {
        _apps = appInfoList;
        _isLoading = false;
      });
    } catch(e, stacktrace) {
      print("[UI] Error loading data: $e");
      print(stacktrace);
      setState(() { _isLoading = false; });
      if (mounted) {
        _showSnackBar('Error loading app data: $e');
      }
    }
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        margin: const EdgeInsets.all(12),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Future<void> _confirmClearAllLimits() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear All Limits?'),
        content: const Text('This will remove all usage limits for all apps.'),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red[400]!,
              foregroundColor: Colors.white,
            ),
            child: const Text('Clear All'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await _clearAllLimits();
    }
  }

  Future<void> _clearAllLimits() async {
    try {
      final packagesWithLimits = _limitsMap.keys.toList();

      for (final packageName in packagesWithLimits) {
        await dbHelper.removeLimit(packageName);
      }

      setState(() {
        _limitsMap.clear();
      });

      _showSnackBar('All usage limits have been cleared');
    } catch (e) {
      _showSnackBar('Error clearing limits: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    List<AppInfo> displayedApps = _apps.where((appInfo) {
      final app = appInfo.app;
      bool matchesSearch = _searchQuery.isEmpty ||
          app.appName.toLowerCase().contains(_searchQuery.toLowerCase()) ||
          app.packageName.toLowerCase().contains(_searchQuery.toLowerCase());

      if (!matchesSearch) return false;

      if (_selectedIndex == 1) {
        return _limitsMap.containsKey(app.packageName);
      }
      return true;
    }).toList();

    if (_selectedIndex == 0 || _selectedIndex == 1) {
      if (_sortByUsageDesc) {
        displayedApps.sort((a, b) {
          final aUsage = _usageMap[a.app.packageName]?.inSeconds ?? 0;
          final bUsage = _usageMap[b.app.packageName]?.inSeconds ?? 0;
          return bUsage.compareTo(aUsage);
        });
      }
    }

    Widget bodyWidget;

    if (_isLoading) {
      bodyWidget = Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(
              valueColor: AlwaysStoppedAnimation<Color>(Theme.of(context).colorScheme.primary),
            ),
            const SizedBox(height: 20),
            Text(
              'Loading app data...',
              style: TextStyle(
                fontSize: 16,
                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
              ),
            ),
          ],
        ),
      );
    } else if (_selectedIndex == 0 || _selectedIndex == 1) {
      if (displayedApps.isEmpty) {
        bodyWidget = Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                _selectedIndex == 0 ? Icons.search_off : Icons.timer_off_outlined,
                size: 80,
                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.4),
              ),
              const SizedBox(height: 16),
              Text(
                _selectedIndex == 0 ? 'No matching apps found' : 'No apps with limits set',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w500,
                  color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                ),
              ),
              if (_selectedIndex == 0 && _searchQuery.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8.0),
                  child: TextButton.icon(
                    icon: const Icon(Icons.clear),
                    label: const Text('Clear search'),
                    onPressed: () {
                      _searchController.clear();
                      setState(() { _searchQuery = ''; });
                    },
                  ),
                ),
            ],
          ),
        );
      } else {
        bodyWidget = Column(
          children: [
            if (_selectedIndex == 0)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    const Text('Sort by usage', style: TextStyle(fontWeight: FontWeight.w500)),
                    Switch(
                      value: _sortByUsageDesc,
                      activeColor: Theme.of(context).colorScheme.primary,
                      onChanged: (val) {
                        setState(() {
                          _sortByUsageDesc = val;
                        });
                      },
                    ),
                  ],
                ),
              ),
            if (_selectedIndex == 1)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12.0, horizontal: 16.0),
                child: FilledButton.icon(
                  icon: const Icon(Icons.delete_outline, size: 20),
                  label: const Text('Clear All Limits'),
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.red[400]!,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: _confirmClearAllLimits,
                ),
              ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.only(top: 8, bottom: 24),
                itemCount: displayedApps.length,
                itemBuilder: (context, index) {
                  final appInfo = displayedApps[index];
                  final app = appInfo.app;
                  final usage = _usageMap[app.packageName];
                  final weeklyUsage = _weeklyUsageMap[app.packageName];
                  final monthlyUsage = _monthlyUsageMap[app.packageName];
                  final limitInfo = _limitsMap[app.packageName];
                  final limitDuration = limitInfo?.limit;
                  final baseUsage = limitInfo?.baseUsage ?? Duration.zero;

                  String usageText = usage != null ? _formatDuration(usage) : 'No data';
                  String weeklyText = weeklyUsage != null ? _formatDuration(weeklyUsage) : 'No data';
                  String monthlyText = monthlyUsage != null ? _formatDuration(monthlyUsage) : 'No data';
                  Duration effectiveUsage = Duration.zero;
                  if (usage != null) {
                      effectiveUsage = usage > baseUsage ? usage - baseUsage : Duration.zero;
                  }

                  final bool overLimitVisual = limitDuration != null && effectiveUsage > limitDuration;

                  // Calculate remaining time with safety checks
                  Duration remainingTime = Duration.zero;
                  if (limitDuration != null) {
                      remainingTime = limitDuration - effectiveUsage;
                      // Clamp to prevent negative values
                      if (remainingTime.isNegative) remainingTime = Duration.zero;
                  }

                  // Calculate percentage with edge case handling
                  double usagePercentage = 0.0;
                  if (limitDuration != null && limitDuration.inSeconds > 0) {
                      final adjustedUsage = effectiveUsage.inSeconds.toDouble();
                      final totalLimit = limitDuration.inSeconds.toDouble();
                      
                      usagePercentage = (adjustedUsage / totalLimit).clamp(0.0, 1.0);
                      
                      // Handle potential floating point precision issues
                      if (usagePercentage > 0.999) usagePercentage = 1.0;
                  }
                  return Slidable(
                    key: ValueKey(app.packageName),
                    endActionPane: ActionPane(
                      motion: const BehindMotion(),
                      children: [
                        if (limitInfo != null)
                          SlidableAction(
                            onPressed: (_) => _removeLimitDialog(app.packageName, app.appName),
                            backgroundColor: Colors.red[400]!,
                            foregroundColor: Colors.white,
                            icon: Icons.timer_off_outlined,
                            label: 'Remove Limit',
                            borderRadius: const BorderRadius.horizontal(left: Radius.circular(16)),
                          ),
                        SlidableAction(
                          onPressed: (_) => _showLimitDialog(app.packageName, app.appName),
                          backgroundColor: Theme.of(context).colorScheme.primary,
                          foregroundColor: Colors.white,
                          icon: limitInfo != null ? Icons.edit : Icons.timer,
                          label: limitInfo != null ? 'Edit Limit' : 'Set Limit',
                          borderRadius: limitInfo != null
                              ? const BorderRadius.horizontal(right: Radius.circular(16))
                              : BorderRadius.circular(16),
                        ),
                      ],
                    ),
                    child: Card(
                      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      elevation: 2,
                      surfaceTintColor: overLimitVisual
                          ? Colors.red.withOpacity(0.1)
                          : null,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                        side: BorderSide(
                          color: overLimitVisual
                              ? Colors.red.withOpacity(0.8)
                              : Colors.transparent,
                          width: 2,
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(12.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(12),
                                  child: Image.memory(app.icon, width: 48, height: 48),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        app.appName,
                                        style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      Text(
                                        app.packageName,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                                if (limitInfo != null)
                                  Chip(
                                    label: Text(
                                      _formatDuration(limitInfo.limit),
                                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                                    ),
                                    avatar: const Icon(Icons.timer, size: 16),
                                    backgroundColor: Theme.of(context).colorScheme.surfaceVariant,
                                    padding: EdgeInsets.zero,
                                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                  ),
                              ],
                            ),
                            const SizedBox(height: 12),

                            // Usage stats
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceAround,
                              children: [
                                _buildUsageStat('Today', usageText, Icons.today),
                                _buildUsageStat('Week', weeklyText, Icons.date_range),
                                _buildUsageStat('Month', monthlyText, Icons.calendar_month),
                              ],
                            ),

                            

                            // Usage bar only shown if limit exists
                            if (limitInfo != null) ...[
                              const SizedBox(height: 16),
                              Row(
                                children: [
                                  Icon(
                                    overLimitVisual ? Icons.warning_amber : Icons.info_outline,
                                    size: 16,
                                    color: overLimitVisual
                                        ? Colors.red
                                        : Theme.of(context).colorScheme.primary,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    overLimitVisual
                                        ? 'Limit exceeded by ${_formatDuration(effectiveUsage - limitDuration)}'
                                        : 'Remaining: ${_formatDuration(remainingTime)}',
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w500,
                                      color: overLimitVisual
                                          ? Colors.red
                                          : Theme.of(context).colorScheme.primary,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: LinearProgressIndicator(
                                  value: usagePercentage,
                                  backgroundColor: Theme.of(context).colorScheme.surfaceVariant,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    overLimitVisual
                                        ? Colors.red
                                        : Theme.of(context).colorScheme.primary,
                                  ),
                                  minHeight: 10,
                                ),
                              ),
                            ],

                            // Actions
                            if (_selectedIndex == 0) ...[
                              const SizedBox(height: 12),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  TextButton.icon(
                                    icon: Icon(
                                      limitInfo != null ? Icons.edit : Icons.timer,
                                      size: 18,
                                    ),
                                    label: Text(
                                      limitInfo != null ? 'Edit Limit' : 'Set Limit',
                                      style: const TextStyle(fontSize: 13),
                                    ),
                                    style: TextButton.styleFrom(
                                      foregroundColor: Theme.of(context).colorScheme.primary,
                                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                    ),
                                    onPressed: () => _showLimitDialog(app.packageName, app.appName),
                                  ),
                                  if (limitInfo != null) ...[
                                    const SizedBox(width: 8),
                                    TextButton.icon(
                                      icon: const Icon(Icons.timer_off_outlined, size: 18),
                                      label: const Text('Remove', style: TextStyle(fontSize: 13)),
                                      style: TextButton.styleFrom(
                                        foregroundColor: Colors.red[400],
                                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                      ),
                                      onPressed: () => _removeLimitDialog(app.packageName, app.appName),
                                    ),
                                  ],
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      }
    } else if (_selectedIndex == 2) {
      // Statistics tab
      bodyWidget = Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'daily', label: Text('Daily')),
                ButtonSegment(value: 'weekly', label: Text('Weekly')),
                ButtonSegment(value: 'monthly', label: Text('Monthly')),
              ],
              selected: {_chartTimePeriod},
              onSelectionChanged: (Set<String> newSelection) {
                setState(() {
                  _chartTimePeriod = newSelection.first;
                });
              },
            ),
          ),
          Expanded(
            child: _buildUsageChart(),
          ),
        ],
      );
    } else {
      bodyWidget = const Center(
        child: Text('Unknown tab'),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: _selectedIndex == 0
            ? TextField(
          controller: _searchController,
          decoration: InputDecoration(
            hintText: 'Search apps...',
            border: InputBorder.none,
            suffixIcon: IconButton(
              icon: const Icon(Icons.clear),
              onPressed: () {
                _searchController.clear();
                setState(() => _searchQuery = '');
              },
            ),
          ),
          onChanged: (value) => setState(() => _searchQuery = value),
        )
            : Text(
          _selectedIndex == 1
              ? 'Limited Apps'
              : 'Usage Statistics',
        ),
        actions: [
          if (_selectedIndex == 0)
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _loadData,
              tooltip: 'Refresh',
            ),
        ],
      ),
      body: bodyWidget,
      floatingActionButton: _selectedIndex == 0
          ? FloatingActionButton(
        onPressed: _loadData,
        tooltip: 'Refresh',
        child: const Icon(Icons.refresh),
      )
          : null,
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: (index) => setState(() => _selectedIndex = index),
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.apps),
            label: 'All Apps',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.timer),
            label: 'Limited',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.insights),
            label: 'Stats',
          ),
        ],
      ),
    );
  }

  Widget _buildUsageStat(String label, String value, IconData icon) {
    return Column(
      children: [
        Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
          ),
        ),
        Text(
          value,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
      ],
    );
  }

Widget _buildUsageChart() {
  final usageMap = _chartTimePeriod == 'daily'
      ? _usageMap
      : _chartTimePeriod == 'weekly'
          ? _weeklyUsageMap
          : _monthlyUsageMap;

  // Filter to only include apps that exist in _apps and have usage
  final topApps = usageMap.entries
      .where((entry) {
        final exists = _apps.any((appInfo) => appInfo.app.packageName == entry.key);
        return exists && entry.value.inMinutes > 0;
      })
      .toList()
    ..sort((a, b) => b.value.compareTo(a.value));

  // Take top 5 after sorting
  final displayedApps = topApps.take(5).toList();

  if (displayedApps.isEmpty) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.bar_chart_outlined,
            size: 60,
            color: Theme.of(context).colorScheme.onSurface.withOpacity(0.3),
          ),
          const SizedBox(height: 16),
          Text(
            'No usage data available',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
            ),
          ),
        ],
      ),
    );
  }

  // Get app names and durations
  final appNames = displayedApps.map((entry) {
    final app = _apps.firstWhere((appInfo) => appInfo.app.packageName == entry.key);
    return app.app.appName;
  }).toList();

  final durations = displayedApps.map((entry) => entry.value.inMinutes.toDouble()).toList();

  return Padding(
    padding: const EdgeInsets.all(16.0),
    child: BarChart(
      BarChartData(
        alignment: BarChartAlignment.spaceAround,
        maxY: durations.reduce((a, b) => a > b ? a : b) * 1.2,
        barTouchData: BarTouchData(
          enabled: true,
          touchTooltipData: BarTouchTooltipData(
            // FIX: Changed from tooltipBgColor to tooltipBackgroundColor
           // tooltipBackgroundColor: Theme.of(context).colorScheme.surface,
            // Added these additional properties for better tooltip appearance
            tooltipPadding: const EdgeInsets.all(8),
            tooltipRoundedRadius: 8,
            tooltipMargin: 8,
            getTooltipItem: (group, groupIndex, rod, rodIndex) {
              return BarTooltipItem(
                '${appNames[groupIndex]}\n${_formatDuration(Duration(minutes: rod.toY.toInt()))}',
                TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontWeight: FontWeight.bold,
                ),
              );
            },
          ),
        ),
        titlesData: FlTitlesData(
          show: true,
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              getTitlesWidget: (value, meta) {
                final index = value.toInt();
                if (index >= 0 && index < appNames.length) {
                  return Padding(
                    padding: const EdgeInsets.only(top: 8.0),
                    child: Text(
                      appNames[index],
                      style: const TextStyle(fontSize: 10),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  );
                }
                return const Text('');
              },
              reservedSize: 40,
            ),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              getTitlesWidget: (value, meta) {
                return Text(
                  '${value.toInt()}m',
                  style: const TextStyle(fontSize: 10),
                );
              },
              reservedSize: 40,
            ),
          ),
          topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        borderData: FlBorderData(show: false),
        barGroups: List.generate(
          durations.length,
          (index) => BarChartGroupData(
            x: index,
            barRods: [
              BarChartRodData(
                toY: durations[index],
                gradient: LinearGradient(
                  colors: _chartGradientColors,
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                ),
                width: 24,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
              ),
            ],
          ),
        ),
        gridData: const FlGridData(show: false),
      ),
    ),
  );
}

  Future<void> _showLimitDialog(String packageName, String appName) async {
    final currentLimit = _limitsMap[packageName]?.limit;
    final currentBase = _limitsMap[packageName]?.baseUsage ?? Duration.zero;

    final hoursController = TextEditingController(
        text: currentLimit != null ? (currentLimit.inHours).toString() : '');
    final minutesController = TextEditingController(
        text: currentLimit != null ? (currentLimit.inMinutes % 60).toString() : '30');
    final baseHoursController = TextEditingController(
        text: currentBase.inHours.toString());
    final baseMinutesController = TextEditingController(
        text: (currentBase.inMinutes % 60).toString());

    final result = await showModalBottomSheet<Map<String, Duration>>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
          ),
          child: StatefulBuilder(
            builder: (context, setState) {
              return SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Text(
                        'Set Usage Limit for $appName',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    const Text(
                      'Daily Usage Limit',
                      style: TextStyle(fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: hoursController,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Hours',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: TextField(
                            controller: minutesController,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Minutes',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    const Text(
                      'Base Usage (optional)',
                      style: TextStyle(fontWeight: FontWeight.w500),
                    ),
                    const Text(
                      'This will be subtracted from daily usage',
                      style: TextStyle(fontSize: 12),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: baseHoursController,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Hours',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: TextField(
                            controller: baseMinutesController,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Minutes',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 32),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton(
                            onPressed: () {
                              final hours = int.tryParse(hoursController.text) ?? 0;
                              final minutes = int.tryParse(minutesController.text) ?? 0;
                              final baseHours = int.tryParse(baseHoursController.text) ?? 0;
                              final baseMinutes = int.tryParse(baseMinutesController.text) ?? 0;

                              if (hours == 0 && minutes == 0) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Please enter a valid limit')),
                                );
                                return;
                              }

                              Navigator.pop(context, {
                                'limit': Duration(hours: hours, minutes: minutes),
                                'base': Duration(hours: baseHours, minutes: baseMinutes),
                              });
                            },
                            child: const Text('Save Limit'),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('Cancel'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
              );
            },
          ),
        );
      },
    );

    if (result != null) {
      try {
        await dbHelper.setLimit(
          packageName,
          appName,
          result['limit']!,
          baseUsage: result['base']!,
        );

        setState(() {
          _limitsMap[packageName] = AppLimit(
            packageName: packageName,
            appName: appName,
            limit: result['limit']!,
            baseUsage: result['base']!,
            notified: false,
          );
        });

        _showSnackBar('Usage limit set for $appName');
      } catch (e) {
        _showSnackBar('Error setting limit: $e');
      }
    }
  }

  Future<void> _removeLimitDialog(String packageName, String appName) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove Usage Limit?'),
        content: Text('Remove the usage limit for $appName?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red[400]!,
              foregroundColor: Colors.white,
            ),
            child: const Text('Remove'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await _removeLimit(packageName, appName);
    }
  }

  Future<void> _removeLimit(String packageName, String appName) async {
    try {
      await dbHelper.removeLimit(packageName);
      setState(() {
        _limitsMap.remove(packageName);
      });
      _showSnackBar('Usage limit removed for $appName');
    } catch (e) {
      _showSnackBar('Error removing limit: $e');
    }
  }
}

class AppInfo {
  final ApplicationWithIcon app;
  final DateTime? installDate;

  AppInfo({
    required this.app,
    this.installDate,
  });
}

