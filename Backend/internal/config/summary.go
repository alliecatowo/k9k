package config

import (
	"crypto/sha256"
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

type Document struct {
	Name    string `json:"name"`
	Path    string `json:"path"`
	Exists  bool   `json:"exists"`
	Content string `json:"content"`
	SHA256  string `json:"sha256"`
}

func LoadDocument(directory, name string) (Document, error) {
	if !validDocument(name) {
		return Document{}, fmt.Errorf("unsupported K9s configuration file %q", name)
	}
	if strings.TrimSpace(directory) == "" {
		var err error
		directory, err = DefaultDirectory()
		if err != nil {
			return Document{}, err
		}
	}
	path := filepath.Join(filepath.Clean(directory), name+".yaml")
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return document(name, path, false, nil), nil
	}
	if err != nil {
		return Document{}, fmt.Errorf("read %q: %w", path, err)
	}
	return document(name, path, true, data), nil
}

func SaveDocument(directory, name, expectedSHA, content string) (Document, error) {
	current, err := LoadDocument(directory, name)
	if err != nil {
		return Document{}, err
	}
	if expectedSHA == "" || expectedSHA != current.SHA256 {
		return Document{}, fmt.Errorf("configuration changed on disk; reload before saving")
	}
	data := []byte(content)
	if len(data) > 1<<20 {
		return Document{}, errors.New("configuration content exceeds 1 MiB")
	}
	if err := validateDocument(name, data); err != nil {
		return Document{}, err
	}
	if err := os.MkdirAll(filepath.Dir(current.Path), 0o700); err != nil {
		return Document{}, err
	}
	temporary, err := os.CreateTemp(filepath.Dir(current.Path), ".k9k-config-")
	if err != nil {
		return Document{}, err
	}
	temporaryName := temporary.Name()
	defer os.Remove(temporaryName)
	if _, err = temporary.Write(data); err == nil {
		err = temporary.Chmod(0o600)
	}
	if closeErr := temporary.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return Document{}, err
	}
	if err := os.Rename(temporaryName, current.Path); err != nil {
		return Document{}, err
	}
	return document(name, current.Path, true, data), nil
}

func document(name, path string, exists bool, data []byte) Document {
	return Document{Name: name, Path: path, Exists: exists, Content: string(data), SHA256: fmt.Sprintf("%x", sha256.Sum256(data))}
}
func validDocument(name string) bool {
	return name == "aliases" || name == "hotkeys" || name == "plugins" || name == "views"
}
func validateDocument(name string, data []byte) error {
	var err error
	switch name {
	case "aliases":
		_, err = ParseAliases(data)
	case "hotkeys":
		_, err = ParseHotkeys(data)
	case "plugins":
		_, err = ParsePlugins(data, "plugins.yaml")
	case "views":
		_, err = ParseViews(data)
	}
	return err
}

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
