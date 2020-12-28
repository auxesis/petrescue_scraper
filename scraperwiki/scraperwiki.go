package scraperwiki

import (
	"database/sql"
	"fmt"
	"log"
	"strings"

	_ "github.com/mattn/go-sqlite3" // database import
)

// SaveSqlite saves data to an sqlite database
func SaveSqlite(k []string, d []map[string]interface{}, n string) (err error) {
	db, err := sql.Open("sqlite3", "./data.sqlite")
	if err != nil {
		log.Fatal(err)
	}
	defer db.Close()

	if !tableExists(db, n) {
		createTable(db, k, d, n)
	}

	for _, e := range d {
		var cls []string
		var vls []string
		for kk, x := range e {
			cls = append(cls, kk)

			switch x.(type) {
			case string:
				vls = append(vls, fmt.Sprintf("%q", x))
			case int:
				vls = append(vls, fmt.Sprintf("%d", x))
			case float64:
				vls = append(vls, fmt.Sprintf("%f", x))
			}
		}

		insertStmt := strings.Builder{}
		insertStmt.WriteString(fmt.Sprintf("insert into %s(", n))
		insertStmt.WriteString(strings.Join(cls, ", "))
		insertStmt.WriteString(") values (")
		insertStmt.WriteString(strings.Join(vls, ", "))
		insertStmt.WriteString(");\n")

		_, err = db.Exec(insertStmt.String())
		if err != nil {
			log.Fatalf("err: %q: %s\n", err, insertStmt.String())
		}
	}
	return err
}

func tableExists(db *sql.DB, n string) bool {
	var count int
	q := fmt.Sprintf("SELECT count(name) FROM sqlite_master WHERE type='table' AND name='%s';", n)
	rows, err := db.Query(q)
	if err != nil {
		log.Fatal(err)
	}
	defer rows.Close()
	for rows.Next() {
		err = rows.Scan(&count)
		if err != nil {
			log.Fatal(err)
		}
	}
	err = rows.Err()
	if err != nil {
		log.Fatal(err)
	}

	return count == 1
}

func createTable(db *sql.DB, k []string, d []map[string]interface{}, n string) {
	stmt := strings.Builder{}
	stmt.WriteString(fmt.Sprintf("create table %s (", n))

	var cols []string
	for kk, x := range d[0] {
		switch x.(type) {
		case string:
			cols = append(cols, kk+" text")
		case int:
			cols = append(cols, kk+" integer")
		case float64:
			cols = append(cols, kk+" real")
		default:
			log.Fatalf("unknown type")
		}
	}
	stmt.WriteString(strings.Join(cols, ", "))
	stmt.WriteString(");\n")
	stmt.WriteString(fmt.Sprintf("delete from %s;\n", n))

	_, err := db.Exec(stmt.String())
	if err != nil {
		log.Fatalf("%q: %s\n", err, stmt)
	}
}
