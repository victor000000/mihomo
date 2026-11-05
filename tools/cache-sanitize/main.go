// cache-sanitize creates a clean cache from an OFFLINE copy. It never replaces
// the source database or operates through the running Mihomo controller.
package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"time"

	bolt "go.etcd.io/bbolt"
)

var credentialURL = regexp.MustCompile(`(?i)([?&](token|access_token|key|secret|password)=|/(s|sub|link)/|/api/v1/client/subscribe|https?://[^/]+:[^/]+@)`)

type result struct {
	RemovedETags   int `json:"removed_etags"`
	CredentialURLs int `json:"credential_urls"`
}

func copyBucket(dst, src *bolt.Bucket) error {
	if err := dst.SetSequence(src.Sequence()); err != nil {
		return err
	}
	return src.ForEach(func(k, v []byte) error {
		if v != nil {
			return dst.Put(k, v)
		}
		child, err := dst.CreateBucket(k)
		if err != nil {
			return err
		}
		return copyBucket(child, src.Bucket(k))
	})
}

func sanitize(input, output, backup string) (r result, err error) {
	in, err := filepath.Abs(input)
	if err != nil {
		return r, err
	}
	out, err := filepath.Abs(output)
	if err != nil {
		return r, err
	}
	back, err := filepath.Abs(backup)
	if err != nil {
		return r, err
	}
	if in == out || in == back || out == back {
		return r, errors.New("input, output and backup must be different files")
	}
	if _, err = os.Stat(in); err != nil {
		return r, errors.New("offline input must already exist")
	}
	// Read-only plus a bounded lock: a writer is never interrupted or waited on.
	src, err := bolt.Open(in, 0600, &bolt.Options{ReadOnly: true, Timeout: 100 * time.Millisecond})
	if err != nil {
		return r, errors.New("offline input unavailable or locked")
	}
	defer src.Close()
	urls := []string{}
	err = src.View(func(tx *bolt.Tx) error {
		b := tx.Bucket([]byte("etag"))
		if b == nil {
			return nil
		}
		return b.ForEach(func(k, v []byte) error {
			r.RemovedETags++
			if credentialURL.Match(k) {
				urls = append(urls, string(k))
			}
			return nil
		})
	})
	if err != nil {
		return r, errors.New("cannot inspect offline cache")
	}
	r.CredentialURLs = len(urls)
	// Never destroy an existing backup or output. Credentials leave the database
	// only into the explicitly supplied private JSON file, before output creation.
	if len(urls) > 0 {
		f, e := os.OpenFile(back, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		if e != nil {
			return r, errors.New("private backup must be a new writable file")
		}
		e = json.NewEncoder(f).Encode(map[string]any{"subscription_urls": urls})
		if e == nil {
			e = f.Sync()
		}
		closeErr := f.Close()
		if e != nil || closeErr != nil {
			return r, errors.New("private backup write failed")
		}
	}
	f, err := os.OpenFile(out, os.O_RDWR|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return r, errors.New("output must be a new file")
	}
	if err = f.Close(); err != nil {
		os.Remove(out)
		return r, errors.New("cannot initialize clean cache")
	}
	completed := false
	defer func() {
		if !completed {
			os.Remove(out)
		}
	}()
	dst, err := bolt.Open(out, 0600, nil)
	if err != nil {
		return r, errors.New("cannot create clean cache")
	}
	err = src.View(func(st *bolt.Tx) error {
		return dst.Update(func(dt *bolt.Tx) error {
			return st.ForEach(func(name []byte, b *bolt.Bucket) error {
				if string(name) == "etag" {
					return nil
				}
				child, e := dt.CreateBucket(name)
				if e != nil {
					return e
				}
				return copyBucket(child, b)
			})
		})
	})
	if err == nil {
		err = dst.View(func(tx *bolt.Tx) error {
			var first error
			for e := range tx.Check() {
				if first == nil {
					first = e
				}
			}
			return first
		})
	}
	closeErr := dst.Close()
	if err != nil || closeErr != nil {
		return r, errors.New("clean cache validation failed")
	}
	completed = true
	return r, nil
}

func main() {
	input := flag.String("input", "", "offline cache snapshot")
	output := flag.String("output", "", "new clean cache file; never the live cache")
	backup := flag.String("credential-backup", "", "new private JSON credential backup")
	flag.Parse()
	if *input == "" || *output == "" || *backup == "" {
		fmt.Fprintln(os.Stderr, "input, output and credential-backup are required")
		os.Exit(2)
	}
	r, err := sanitize(*input, *output, *backup)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	json.NewEncoder(os.Stdout).Encode(r)
}
