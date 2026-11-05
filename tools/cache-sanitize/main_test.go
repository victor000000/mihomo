package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	bolt "go.etcd.io/bbolt"
)

func fixture(t *testing.T, dir string) (string, string) {
	t.Helper()
	p := filepath.Join(dir, "cache.db")
	url := "https://example.invalid/" + "sub/" + strings.Repeat("a", 32)
	db, e := bolt.Open(p, 0600, nil)
	if e != nil {
		t.Fatal(e)
	}
	e = db.Update(func(tx *bolt.Tx) error {
		b, e := tx.CreateBucket([]byte("etag"))
		if e != nil {
			return e
		}
		if e = b.Put([]byte(url), []byte("etag-metadata")); e != nil {
			return e
		}
		selected, e := tx.CreateBucket([]byte("selected"))
		if e != nil {
			return e
		}
		selected.SetSequence(17)
		if e = selected.Put([]byte("CHATGPT"), []byte("fixture-proxy")); e != nil {
			return e
		}
		nested, e := selected.CreateBucket([]byte("nested"))
		if e != nil {
			return e
		}
		return nested.Put([]byte("business-data"), []byte("preserved"))
	})
	if e != nil {
		t.Fatal(e)
	}
	db.Close()
	return p, url
}

func TestSanitizePreservesDataAndRemovesSecretBytes(t *testing.T) {
	dir := t.TempDir()
	src, url := fixture(t, dir)
	before, _ := os.ReadFile(src)
	out := filepath.Join(dir, "clean.db")
	back := filepath.Join(dir, "private.json")
	r, e := sanitize(src, out, back)
	if e != nil {
		t.Fatal(e)
	}
	if r.RemovedETags != 1 || r.CredentialURLs != 1 {
		t.Fatal(r)
	}
	after, _ := os.ReadFile(src)
	if !bytes.Equal(before, after) {
		t.Fatal("source changed")
	}
	clean, _ := os.ReadFile(out)
	if bytes.Contains(clean, []byte(url)) {
		t.Fatal("secret remains in clean database")
	}
	backup, _ := os.ReadFile(back)
	if !bytes.Contains(backup, []byte(url)) {
		t.Fatal("credential backup missing")
	}
	db, e := bolt.Open(out, 0600, &bolt.Options{ReadOnly: true})
	if e != nil {
		t.Fatal(e)
	}
	defer db.Close()
	e = db.View(func(tx *bolt.Tx) error {
		if tx.Bucket([]byte("etag")) != nil {
			t.Fatal("ETag bucket retained")
		}
		b := tx.Bucket([]byte("selected"))
		if b.Sequence() != 17 || string(b.Get([]byte("CHATGPT"))) != "fixture-proxy" {
			t.Fatal("selection lost")
		}
		if string(b.Bucket([]byte("nested")).Get([]byte("business-data"))) != "preserved" {
			t.Fatal("nested data lost")
		}
		return nil
	})
	if e != nil {
		t.Fatal(e)
	}
}
func TestBackupFailureDoesNotTouchSourceOrCreateOutput(t *testing.T) {
	dir := t.TempDir()
	src, _ := fixture(t, dir)
	before, _ := os.ReadFile(src)
	out := filepath.Join(dir, "clean.db")
	if _, e := sanitize(src, out, filepath.Join(dir, "missing", "private.json")); e == nil {
		t.Fatal("missing backup accepted")
	}
	after, _ := os.ReadFile(src)
	if !bytes.Equal(before, after) {
		t.Fatal("source changed")
	}
	if _, e := os.Stat(out); !os.IsNotExist(e) {
		t.Fatal("output created without backup")
	}
}
func TestLockedWriterIsNotInterrupted(t *testing.T) {
	dir := t.TempDir()
	src, _ := fixture(t, dir)
	db, e := bolt.Open(src, 0600, nil)
	if e != nil {
		t.Fatal(e)
	}
	defer db.Close()
	if _, e = sanitize(src, filepath.Join(dir, "clean.db"), filepath.Join(dir, "private.json")); e == nil {
		t.Fatal("writer lock ignored")
	}
}
func TestSourceCannotBeOverwritten(t *testing.T) {
	dir := t.TempDir()
	src, _ := fixture(t, dir)
	if _, e := sanitize(src, src, filepath.Join(dir, "private.json")); e == nil {
		t.Fatal("source overwrite accepted")
	}
}

func TestExistingOutputAndBackupArePreserved(t *testing.T) {
	for _, name := range []string{"output", "backup"} {
		t.Run(name, func(t *testing.T) {
			dir := t.TempDir()
			src, _ := fixture(t, dir)
			before, _ := os.ReadFile(src)
			out := filepath.Join(dir, "clean.db")
			back := filepath.Join(dir, "private.json")
			existing := out
			if name == "backup" {
				existing = back
			}
			sentinel := []byte("existing private data")
			if e := os.WriteFile(existing, sentinel, 0600); e != nil {
				t.Fatal(e)
			}
			if _, e := sanitize(src, out, back); e == nil {
				t.Fatal("existing file accepted")
			}
			got, _ := os.ReadFile(existing)
			if !bytes.Equal(got, sentinel) {
				t.Fatal("existing file overwritten")
			}
			after, _ := os.ReadFile(src)
			if !bytes.Equal(before, after) {
				t.Fatal("source changed")
			}
		})
	}
}
