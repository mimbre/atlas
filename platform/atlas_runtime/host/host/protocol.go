package host

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"unicode/utf8"
)

const recordLimit = 1048576

// jsonRecord decodes one bounded object, rejecting duplicate keys at any depth;
// encoding/json alone would keep the last duplicate.
func jsonRecord(line []byte, limit int) (map[string]any, error) {
	if len(line) > limit {
		return nil, errors.New("Native protocol record exceeds its size limit")
	}
	if !utf8.Valid(line) {
		return nil, errors.New("Native protocol record is not UTF-8")
	}
	decoder := json.NewDecoder(bytes.NewReader(line))
	decoder.UseNumber()
	value, err := jsonValue(decoder)
	if err != nil {
		return nil, err
	}
	if _, err = decoder.Token(); err != io.EOF {
		return nil, errors.New("Native protocol record has extra data")
	}
	record, ok := value.(map[string]any)
	if !ok {
		return nil, errors.New("Native protocol record must be an object")
	}
	return record, nil
}

func jsonValue(decoder *json.Decoder) (any, error) {
	token, err := decoder.Token()
	if err != nil {
		return nil, err
	}
	switch token {
	case json.Delim('{'):
		object := map[string]any{}
		for decoder.More() {
			if token, err = decoder.Token(); err != nil {
				return nil, err
			}
			key, _ := token.(string)
			if _, seen := object[key]; seen {
				return nil, errors.New("Duplicate JSON key")
			}
			if object[key], err = jsonValue(decoder); err != nil {
				return nil, err
			}
		}
		_, err = decoder.Token()
		return object, err
	case json.Delim('['):
		array := []any{}
		for decoder.More() {
			item, err := jsonValue(decoder)
			if err != nil {
				return nil, err
			}
			array = append(array, item)
		}
		_, err = decoder.Token()
		return array, err
	}
	return token, nil
}

func emit(record map[string]any) error {
	data, err := json.Marshal(record)
	if err != nil {
		return err
	}
	_, err = os.Stdout.Write(append(data, '\n'))
	return err
}

// emitRaw forwards a validated native record byte-for-byte, avoiding re-encoding drift.
func emitRaw(prefix string, record []byte, suffix string) error {
	line := make([]byte, 0, len(prefix)+len(record)+len(suffix)+1)
	line = append(append(append(append(line, prefix...), record...), suffix...), '\n')
	_, err := os.Stdout.Write(line)
	return err
}
