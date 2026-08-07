// Package config parses the K9s configuration files that K9k can present in
// its native UI. It intentionally models the portable, user-facing parts of
// the K9s formats rather than importing K9s' internal packages.
package config

import (
	"fmt"
	"os"
)

// LoadAliases reads an aliases.yaml-compatible file.
func LoadAliases(path string) (map[string]Alias, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read aliases %q: %w", path, err)
	}
	return ParseAliases(data)
}

// LoadHotkeys reads a hotkeys.yaml-compatible file.
func LoadHotkeys(path string) (map[string]Hotkey, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read hotkeys %q: %w", path, err)
	}
	return ParseHotkeys(data)
}

// LoadPlugins reads a K9s plugins file. sourceName is used as the plugin name
// for K9s' single-plugin file format; pass the file path in normal use.
func LoadPlugins(path string) (map[string]Plugin, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read plugins %q: %w", path, err)
	}
	return ParsePlugins(data, path)
}

// LoadViews reads a views.yaml-compatible file.
func LoadViews(path string) (map[string]View, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read views %q: %w", path, err)
	}
	return ParseViews(data)
}
