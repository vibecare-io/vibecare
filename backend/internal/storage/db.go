package storage

import (
	"database/sql"
	"embed"

	_ "github.com/mattn/go-sqlite3"
	"github.com/pressly/goose/v3"
)

//go:embed migrations/*.sql
var embedMigrations embed.FS

// DB wraps the SQL database connection
type DB struct {
	*sql.DB
}

// New creates a new database connection and runs migrations
func New(dbPath string) (*DB, error) {
	// Open database connection with optimizations for concurrent access
	// - WAL mode: allows concurrent reads during writes
	// - busy_timeout: wait up to 5s for locks instead of failing immediately
	// - foreign_keys: enforce referential integrity
	sqlDB, err := sql.Open("sqlite3", dbPath+"?_foreign_keys=on&_journal_mode=WAL&_busy_timeout=5000")
	if err != nil {
		return nil, err
	}

	// SQLite should use a single connection for proper write serialization
	sqlDB.SetMaxOpenConns(1)
	sqlDB.SetMaxIdleConns(1)

	// Run migrations
	goose.SetBaseFS(embedMigrations)
	if err := goose.SetDialect("sqlite3"); err != nil {
		return nil, err
	}

	if err := goose.Up(sqlDB, "migrations"); err != nil {
		return nil, err
	}

	return &DB{DB: sqlDB}, nil
}

// Close closes the database connection
func (db *DB) Close() error {
	return db.DB.Close()
}
