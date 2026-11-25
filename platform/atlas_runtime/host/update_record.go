package main

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"time"
)

// The outcome of an update, apart from update.go so that only update.json is written atomically
// here (the Runtime home census ties a .tmp write to the home files joined in its source file).

// record writes update.json: done with the result, or the step that failed and why.
func record(dir, wanted string, result map[string]any, err error) {
	outcome := map[string]any{"build": wanted, "at": time.Now().UTC().Format(time.RFC3339)}
	if err == nil {
		for key, value := range result {
			outcome[key] = value
		}
		outcome["result"], outcome["state"] = result["state"], "done"
	} else {
		outcome["state"] = "failed"
		outcome["error"] = err.Error()
		var failure interface{ Result() map[string]any }
		if errors.As(err, &failure) {
			for key, value := range failure.Result() {
				outcome[key] = value
			}
		}
	}
	data, _ := json.Marshal(outcome)
	outcomePath := filepath.Join(dir, "update.json")
	temporary := outcomePath + ".tmp"
	if os.WriteFile(temporary, append(data, '\n'), 0600) == nil {
		os.Rename(temporary, outcomePath)
	}
}
