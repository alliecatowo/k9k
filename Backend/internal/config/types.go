package config

import "strings"

// Alias is one K9s aliases.yaml entry. Target is K9s' GVR-or-alias string,
// for example "apps/v1/deployments" or another configured alias.
type Alias struct {
	Name   string `json:"name"`
	Target string `json:"target"`
}

// Hotkey is one K9s hotKeys entry. Shortcut corresponds to K9s' shortCut
// YAML spelling; the Go name is normalized for callers.
type Hotkey struct {
	Name        string `json:"name"`
	Shortcut    string `json:"shortcut"`
	Override    bool   `json:"override"`
	Description string `json:"description"`
	Command     string `json:"command"`
	KeepHistory bool   `json:"keepHistory"`
}

// Plugin is the native representation of a K9s plugin declaration. Confirm
// remains a pointer because K9s distinguishes an omitted confirm value from
// an explicit false value.
type Plugin struct {
	Name        string   `json:"name"`
	Scopes      []string `json:"scopes"`
	Shortcut    string   `json:"shortcut"`
	Override    bool     `json:"override"`
	Description string   `json:"description"`
	Command     string   `json:"command"`
	Args        []string `json:"args"`
	Background  bool     `json:"background"`
	Confirm     *bool    `json:"confirm,omitempty"`
	Dangerous   bool     `json:"dangerous"`
}

// ShouldConfirm mirrors K9s' behaviour for the supported plugin subset. K9s
// only defaults confirmation to true when input controls are configured;
// K9k's focused parser does not expose those controls, so an omitted value is
// false.
func (p Plugin) ShouldConfirm() bool {
	return p.Confirm != nil && *p.Confirm
}

// AppliesTo reports K9s scope eligibility. A scope of "all" applies to every
// resource; all other scopes are exact aliases, as in K9s' action binding.
func (p Plugin) AppliesTo(aliases ...string) bool {
	for _, scope := range p.Scopes {
		if scope == "all" {
			return true
		}
		for _, alias := range aliases {
			if scope == alias {
				return true
			}
		}
	}
	return false
}

// View is one K9s custom-view entry, keyed by its GVR (optionally followed by
// @namespace or @namespace-regexp). Columns retain their declared order.
type View struct {
	Key        string   `json:"key"`
	Columns    []string `json:"columns"`
	SortColumn string   `json:"sortColumn"`
}

// Jump mirrors K9s jumps.yaml. SourceGVR identifies the selected resource;
// target and selectors are applied by the native browser when the user invokes
// the configured jump.
type Jump struct {
	SourceGVR       string `json:"sourceGVR"`
	TargetGVR       string `json:"targetGVR"`
	LabelSelector   string `json:"labelSelector"`
	FieldSelector   string `json:"fieldSelector"`
	TargetNamespace string `json:"targetNamespace"`
}

// HasColumns reports whether the view overrides visible columns.
func (v View) HasColumns() bool { return len(v.Columns) != 0 }

// Sort parses K9s' sortColumn syntax: column-name:asc or column-name:desc.
// It intentionally reports an error only when a caller asks to use a malformed
// sort spec, matching K9s' lazy validation.
func (v View) Sort() (column string, ascending bool, err error) {
	if v.SortColumn == "" {
		return "", false, ErrNoSortColumn
	}
	parts := strings.Split(v.SortColumn, ":")
	if len(parts) < 2 {
		return "", false, &SortColumnError{Value: v.SortColumn}
	}
	return parts[0], parts[1] == "asc", nil
}
