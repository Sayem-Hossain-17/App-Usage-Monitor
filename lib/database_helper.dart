import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'app_limit.dart';

class DatabaseHelper {
  static final DatabaseHelper _instance = DatabaseHelper._internal();
  static Database? _database;

  factory DatabaseHelper() => _instance;

  DatabaseHelper._internal();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final path = join(await getDatabasesPath(), 'app_limits.db');
    return openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE app_limits(
            packageName TEXT PRIMARY KEY,
            appName TEXT,
            limitMinutes INTEGER,
            baseUsageMinutes INTEGER,
            notified INTEGER
          )
        ''');
      },
    );
  }

  Future<Map<String, AppLimit>> getAllLimits() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query('app_limits');
    return {
      for (var map in maps)
        map['packageName']: AppLimit(
          packageName: map['packageName'],
          appName: map['appName'],
          limit: Duration(minutes: map['limitMinutes']),
          baseUsage: Duration(minutes: map['baseUsageMinutes'] ?? 0),
          notified: map['notified'] == 1,
        )
    };
  }

  Future<void> setLimit(
      String packageName,
      String appName,
      Duration limit, {
        Duration baseUsage = Duration.zero,
        bool notified = false,
      }) async {
    final db = await database;
    await db.insert(
      'app_limits',
      {
        'packageName': packageName,
        'appName': appName,
        'limitMinutes': limit.inMinutes,
        'baseUsageMinutes': baseUsage.inMinutes,
        'notified': notified ? 1 : 0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> removeLimit(String packageName) async {
    final db = await database;
    await db.delete(
      'app_limits',
      where: 'packageName = ?',
      whereArgs: [packageName],
    );
  }

  Future<void> updateNotifiedStatus(String packageName, bool notified) async {
    final db = await database;
    await db.update(
      'app_limits',
      {'notified': notified ? 1 : 0},
      where: 'packageName = ?',
      whereArgs: [packageName],
    );
  }
}