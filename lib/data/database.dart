/// Локальная база: список, прогресс, загрузки. Одна на приложение.
library;

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

class AppDatabase {
  AppDatabase._(this.db);

  final Database db;

  static const int _version = 1;

  static Future<AppDatabase> open() async {
    final path = p.join(await getDatabasesPath(), 'anipocket.db');
    final database = await openDatabase(
      path,
      version: _version,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE watchlist (
            source          TEXT    NOT NULL,
            anime_id        TEXT    NOT NULL,
            title           TEXT    NOT NULL,
            poster_url      TEXT,
            status          TEXT    NOT NULL DEFAULT 'watching',
            rating          INTEGER,
            episodes_total  INTEGER,
            last_episode    INTEGER NOT NULL DEFAULT 0,
            note            TEXT,
            updated_at      INTEGER NOT NULL,
            PRIMARY KEY (source, anime_id)
          )
        ''');
        await db.execute(
          'CREATE INDEX ix_watchlist_status ON watchlist (status, updated_at DESC)',
        );

        await db.execute('''
          CREATE TABLE progress (
            source      TEXT    NOT NULL,
            anime_id    TEXT    NOT NULL,
            episode     INTEGER NOT NULL,
            position    REAL    NOT NULL DEFAULT 0,
            duration    REAL,
            completed   INTEGER NOT NULL DEFAULT 0,
            translation TEXT,
            player_key  TEXT,
            updated_at  INTEGER NOT NULL,
            PRIMARY KEY (source, anime_id, episode)
          )
        ''');
        await db.execute(
          'CREATE INDEX ix_progress_updated ON progress (updated_at DESC)',
        );

        await db.execute('''
          CREATE TABLE downloads (
            id             INTEGER PRIMARY KEY AUTOINCREMENT,
            source         TEXT    NOT NULL,
            anime_id       TEXT    NOT NULL,
            anime_title    TEXT    NOT NULL,
            poster_url     TEXT,
            episode        INTEGER NOT NULL,
            translation    TEXT    NOT NULL DEFAULT '',
            player_key     TEXT    NOT NULL DEFAULT '',
            file_path      TEXT    NOT NULL,
            status         TEXT    NOT NULL DEFAULT 'queued',
            quality        INTEGER,
            kind           TEXT    NOT NULL DEFAULT 'mp4',
            url            TEXT    NOT NULL DEFAULT '',
            headers        TEXT    NOT NULL DEFAULT '{}',
            received_bytes INTEGER NOT NULL DEFAULT 0,
            total_bytes    INTEGER,
            segments_done  INTEGER NOT NULL DEFAULT 0,
            segments_total INTEGER,
            error          TEXT,
            created_at     INTEGER NOT NULL,
            updated_at     INTEGER NOT NULL
          )
        ''');
        await db.execute(
          'CREATE UNIQUE INDEX ix_downloads_episode '
          'ON downloads (source, anime_id, episode, translation)',
        );
      },
    );
    return AppDatabase._(database);
  }

  Future<void> close() => db.close();
}
