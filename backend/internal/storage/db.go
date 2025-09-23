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
	// Open database connection
	sqlDB, err := sql.Open("sqlite3", dbPath+"?_foreign_keys=on")
	if err != nil {
		return nil, err
	}

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