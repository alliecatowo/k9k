package config

import (
	"errors"
	"fmt"
	"path/filepath"
	"strconv"
	"strings"

	"gopkg.in/yaml.v3"
)

var (
	// ErrNoSortColumn is returned when a view has no sortColumn setting.
	ErrNoSortColumn = errors.New("no sort column specified")
)

// SortColumnError identifies an invalid K9s sortColumn value.
type SortColumnError struct{ Value string }

func (e *SortColumnError) Error() string {
	return fmt.Sprintf("invalid sort column spec %q: must be col-name:asc|desc", e.Value)
}

// ParseAliases parses K9s' aliases.yaml format.
func ParseAliases(data []byte) (map[string]Alias, error) {
	var input struct {
		Aliases map[string]string `yaml:"aliases"`
	}
	if err := yaml.Unmarshal(data, &input); err != nil {
		return nil, fmt.Errorf("parse aliases: %w", err)
	}
	if input.Aliases == nil {
		return nil, errors.New("parse aliases: aliases is required")
	}

	aliases := make(map[string]Alias, len(input.Aliases))
	for name, target := range input.Aliases {
		name, target = strings.TrimSpace(name), strings.TrimSpace(target)
		aliases[name] = Alias{Name: name, Target: target}
	}
	return aliases, nil
}

// ParseHotkeys parses K9s' hotkeys.yaml format.
func ParseHotkeys(data []byte) (map[string]Hotkey, error) {
	var input struct {
		Hotkeys map[string]rawHotkey `yaml:"hotKeys"`
	}
	if err := yaml.Unmarshal(data, &input); err != nil {
		return nil, fmt.Errorf("parse hotkeys: %w", err)
	}
	if input.Hotkeys == nil {
		return nil, errors.New("parse hotkeys: hotKeys is required")
	}

	hotkeys := make(map[string]Hotkey, len(input.Hotkeys))
	for name, hotkey := range input.Hotkeys {
		name = strings.TrimSpace(name)
		hotkeys[name] = Hotkey{
			Name:        name,
			Shortcut:    strings.TrimSpace(hotkey.Shortcut),
			Override:    hotkey.Override,
			Description: strings.TrimSpace(hotkey.Description),
			Command:     strings.TrimSpace(hotkey.Command),
			KeepHistory: hotkey.KeepHistory,
		}
	}
	return hotkeys, nil
}

// ParsePlugins parses all three K9s plugin file layouts:
//
//   - plugins: { name: ... } (the normal plugins.yaml layout)
//   - name: ...                (the multi-plugin file layout)
//   - shortCut: ...            (a single plugin named from sourceName)
func ParsePlugins(data []byte, sourceName string) (map[string]Plugin, error) {
	var root map[string]yaml.Node
	if err := yaml.Unmarshal(data, &root); err != nil {
		return nil, fmt.Errorf("parse plugins: %w", err)
	}
	if root == nil {
		return nil, errors.New("parse plugins: expected a mapping")
	}

	if node, ok := root["plugins"]; ok {
		if len(root) != 1 {
			return nil, errors.New("parse plugins: plugins cannot be combined with other top-level fields")
		}
		plugins, err := parsePluginMap(node)
		if err != nil {
			return nil, fmt.Errorf("parse plugins: %w", err)
		}
		return plugins, nil
	}

	if isPluginNode(root) {
		name := strings.TrimSuffix(filepath.Base(sourceName), filepath.Ext(sourceName))
		if name == "." || name == "" {
			return nil, errors.New("parse plugins: source name is required for a single plugin")
		}
		plugin, err := parsePluginNode(mapToNode(root))
		if err != nil {
			return nil, fmt.Errorf("parse plugin %q: %w", name, err)
		}
		plugin.Name = name
		return map[string]Plugin{name: plugin}, nil
	}

	plugins := make(map[string]Plugin, len(root))
	for name, node := range root {
		plugin, err := parsePluginNode(node)
		if err != nil {
			return nil, fmt.Errorf("parse plugin %q: %w", name, err)
		}
		name = strings.TrimSpace(name)
		plugin.Name = name
		plugins[name] = plugin
	}
	return plugins, nil
}

// ParseViews parses K9s' views.yaml format.
func ParseViews(data []byte) (map[string]View, error) {
	var input struct {
		Views map[string]rawView `yaml:"views"`
	}
	if err := yaml.Unmarshal(data, &input); err != nil {
		return nil, fmt.Errorf("parse views: %w", err)
	}
	if input.Views == nil {
		return nil, errors.New("parse views: views is required")
	}

	views := make(map[string]View, len(input.Views))
	for key, view := range input.Views {
		if view.Columns == nil {
			return nil, fmt.Errorf("parse view %q: columns is required", key)
		}
		key = strings.TrimSpace(key)
		views[key] = View{
			Key:        key,
			Columns:    trimStrings(view.Columns),
			SortColumn: strings.TrimSpace(view.SortColumn),
		}
	}
	return views, nil
}

// ParseJumps parses K9s' jumps.yaml mapping. Validation intentionally keeps
// source-target rules useful to a GUI: targetGVR is required, while a jump
// without selectors simply opens the matching target collection.
func ParseJumps(data []byte) (map[string]Jump, error) {
	var input struct {
		Jumps map[string]struct {
			TargetGVR       string `yaml:"targetGVR"`
			LabelSelector   string `yaml:"labelSelector"`
			FieldSelector   string `yaml:"fieldSelector"`
			TargetNamespace string `yaml:"targetNamespace"`
		} `yaml:"jumps"`
	}
	if err := yaml.Unmarshal(data, &input); err != nil {
		return nil, fmt.Errorf("parse jumps: %w", err)
	}
	if input.Jumps == nil {
		return nil, errors.New("parse jumps: jumps is required")
	}
	result := make(map[string]Jump, len(input.Jumps))
	for source, rule := range input.Jumps {
		source, target := strings.TrimSpace(source), strings.TrimSpace(rule.TargetGVR)
		if source == "" || target == "" {
			return nil, fmt.Errorf("parse jump %q: targetGVR is required", source)
		}
		result[source] = Jump{SourceGVR: source, TargetGVR: target, LabelSelector: strings.TrimSpace(rule.LabelSelector), FieldSelector: strings.TrimSpace(rule.FieldSelector), TargetNamespace: strings.TrimSpace(rule.TargetNamespace)}
	}
	return result, nil
}

type rawHotkey struct {
	Shortcut    string `yaml:"shortCut"`
	Override    bool   `yaml:"override"`
	Description string `yaml:"description"`
	Command     string `yaml:"command"`
	KeepHistory bool   `yaml:"keepHistory"`
}

type rawPlugin struct {
	Scopes      []string    `yaml:"scopes"`
	Shortcut    string      `yaml:"shortCut"`
	Override    bool        `yaml:"override"`
	Description string      `yaml:"description"`
	Command     string      `yaml:"command"`
	Args        []yaml.Node `yaml:"args"`
	Background  bool        `yaml:"background"`
	Confirm     *bool       `yaml:"confirm"`
	Dangerous   bool        `yaml:"dangerous"`
}

type rawView struct {
	Columns    []string `yaml:"columns"`
	SortColumn string   `yaml:"sortColumn"`
}

func parsePluginMap(node yaml.Node) (map[string]Plugin, error) {
	if node.Kind != yaml.MappingNode {
		return nil, errors.New("plugins must be a mapping")
	}
	plugins := make(map[string]Plugin, len(node.Content)/2)
	for i := 0; i < len(node.Content); i += 2 {
		name := strings.TrimSpace(node.Content[i].Value)
		plugin, err := parsePluginNode(*node.Content[i+1])
		if err != nil {
			return nil, fmt.Errorf("plugin %q: %w", name, err)
		}
		plugin.Name = name
		plugins[name] = plugin
	}
	return plugins, nil
}

func parsePluginNode(node yaml.Node) (Plugin, error) {
	var raw rawPlugin
	if err := node.Decode(&raw); err != nil {
		return Plugin{}, err
	}
	if raw.Scopes == nil {
		return Plugin{}, errors.New("scopes is required")
	}
	if strings.TrimSpace(raw.Shortcut) == "" {
		return Plugin{}, errors.New("shortCut is required")
	}
	if strings.TrimSpace(raw.Description) == "" {
		return Plugin{}, errors.New("description is required")
	}
	if strings.TrimSpace(raw.Command) == "" {
		return Plugin{}, errors.New("command is required")
	}
	args, err := normalizeArgs(raw.Args)
	if err != nil {
		return Plugin{}, err
	}
	return Plugin{
		Scopes:      trimStrings(raw.Scopes),
		Shortcut:    strings.TrimSpace(raw.Shortcut),
		Override:    raw.Override,
		Description: strings.TrimSpace(raw.Description),
		Command:     strings.TrimSpace(raw.Command),
		Args:        args,
		Background:  raw.Background,
		Confirm:     raw.Confirm,
		Dangerous:   raw.Dangerous,
	}, nil
}

func normalizeArgs(nodes []yaml.Node) ([]string, error) {
	args := make([]string, 0, len(nodes))
	for _, node := range nodes {
		if node.Kind != yaml.ScalarNode {
			return nil, fmt.Errorf("args entries must be strings or numbers, got %s", yamlKind(node.Kind))
		}
		switch node.Tag {
		case "!!str", "!!int", "!!float":
			args = append(args, node.Value)
		default:
			return nil, fmt.Errorf("args entries must be strings or numbers, got %s", node.Tag)
		}
	}
	return args, nil
}

func isPluginNode(root map[string]yaml.Node) bool {
	for field := range root {
		switch field {
		case "shortCut", "override", "description", "confirm", "dangerous", "scopes", "command", "background", "overwriteOutput", "args", "inputs", "pipes":
			return true
		}
	}
	return false
}

func mapToNode(mapping map[string]yaml.Node) yaml.Node {
	node := yaml.Node{Kind: yaml.MappingNode, Tag: "!!map"}
	for key, value := range mapping {
		node.Content = append(node.Content,
			&yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: key},
			&value,
		)
	}
	return node
}

func trimStrings(values []string) []string {
	trimmed := make([]string, len(values))
	for i, value := range values {
		trimmed[i] = strings.TrimSpace(value)
	}
	return trimmed
}

func yamlKind(kind yaml.Kind) string {
	if kind == yaml.SequenceNode {
		return "sequence"
	}
	if kind == yaml.MappingNode {
		return "mapping"
	}
	return strconv.Itoa(int(kind))
}
