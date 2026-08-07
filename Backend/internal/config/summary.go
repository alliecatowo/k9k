package config

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

const (
	aliasesFile = "aliases.yaml"
	hotkeysFile = "hotkeys.yaml"
	pluginsFile = "plugins.yaml"
	viewsFile   = "views.yaml"
)

// FileStatus describes one optional K9s configuration file. A missing file is
// normal: K9s treats every customization file as optional.
type FileStatus struct {
	Path    string `json:"path"`
	Present bool   `json:"present"`
	Error   string `json:"error,omitempty"`
}

// Summary is the read-only, JSON-friendly representation of K9s user
// configuration consumed by K9k's native UI. Invalid individual files are
// reported on Files while valid sibling files remain available.
type Summary struct {
	Directory string                `json:"directory"`
	Files     map[string]FileStatus `json:"files"`
	Aliases   []Alias               `json:"aliases"`
	Hotkeys   []Hotkey              `json:"hotkeys"`
	Plugins   []Plugin              `json:"plugins"`
	Views     []View                `json:"views"`
}

// DefaultDirectory resolves the K9s configuration directory without reading
// any configuration. K9S_CONFIG_DIR matches K9s' explicit override; otherwise
// K9s follows XDG_CONFIG_HOME and finally ~/.config/k9s.
func DefaultDirectory() (string, error) {
	if directory := strings.TrimSpace(os.Getenv("K9S_CONFIG_DIR")); directory != "" {
		return filepath.Clean(directory), nil
	}
	if base := strings.TrimSpace(os.Getenv("XDG_CONFIG_HOME")); base != "" {
		return filepath.Join(base, "k9s"), nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("resolve home directory for K9s configuration: %w", err)
	}
	return filepath.Join(home, ".config", "k9s"), nil
}

// LoadSummary loads K9s' optional customization files from directory. Missing
// files are represented as present:false rather than being errors, so a fresh
// K9s installation and partially configured directories are always usable.
func LoadSummary(directory string) (Summary, error) {
	if strings.TrimSpace(directory) == "" {
		var err error
		directory, err = DefaultDirectory()
		if err != nil {
			return Summary{}, err
		}
	}
	directory = filepath.Clean(directory)

	summary := Summary{
		Directory: directory,
		Files: map[string]FileStatus{
			"aliases": fileStatus(directory, aliasesFile),
			"hotkeys": fileStatus(directory, hotkeysFile),
			"plugins": fileStatus(directory, pluginsFile),
			"views":   fileStatus(directory, viewsFile),
		},
		Aliases: []Alias{}, Hotkeys: []Hotkey{}, Plugins: []Plugin{}, Views: []View{},
	}

	if summary.Files["aliases"].Present {
		if values, err := LoadAliases(summary.Files["aliases"].Path); err != nil {
			summary.setFileError("aliases", err)
		} else {
			summary.Aliases = sortedAliases(values)
		}
	}
	if summary.Files["hotkeys"].Present {
		if values, err := LoadHotkeys(summary.Files["hotkeys"].Path); err != nil {
			summary.setFileError("hotkeys", err)
		} else {
			summary.Hotkeys = sortedHotkeys(values)
		}
	}
	if summary.Files["plugins"].Present {
		if values, err := LoadPlugins(summary.Files["plugins"].Path); err != nil {
			summary.setFileError("plugins", err)
		} else {
			summary.Plugins = sortedPlugins(values)
		}
	}
	if summary.Files["views"].Present {
		if values, err := LoadViews(summary.Files["views"].Path); err != nil {
			summary.setFileError("views", err)
		} else {
			summary.Views = sortedViews(values)
		}
	}
	return summary, nil
}

func fileStatus(directory, name string) FileStatus {
	path := filepath.Join(directory, name)
	_, err := os.Stat(path)
	if err == nil {
		return FileStatus{Path: path, Present: true}
	}
	if errors.Is(err, os.ErrNotExist) {
		return FileStatus{Path: path}
	}
	return FileStatus{Path: path, Error: fmt.Sprintf("inspect %q: %v", path, err)}
}

func (s *Summary) setFileError(name string, err error) {
	status := s.Files[name]
	status.Error = err.Error()
	s.Files[name] = status
}

func sortedAliases(values map[string]Alias) []Alias {
	result := make([]Alias, 0, len(values))
	for _, value := range values {
		result = append(result, value)
	}
	sort.Slice(result, func(i, j int) bool { return result[i].Name < result[j].Name })
	return result
}

func sortedHotkeys(values map[string]Hotkey) []Hotkey {
	result := make([]Hotkey, 0, len(values))
	for _, value := range values {
		result = append(result, value)
	}
	sort.Slice(result, func(i, j int) bool { return result[i].Name < result[j].Name })
	return result
}

func sortedPlugins(values map[string]Plugin) []Plugin {
	result := make([]Plugin, 0, len(values))
	for _, value := range values {
		result = append(result, value)
	}
	sort.Slice(result, func(i, j int) bool { return result[i].Name < result[j].Name })
	return result
}

func sortedViews(values map[string]View) []View {
	result := make([]View, 0, len(values))
	for _, value := range values {
		result = append(result, value)
	}
	sort.Slice(result, func(i, j int) bool { return result[i].Key < result[j].Key })
	return result
}
