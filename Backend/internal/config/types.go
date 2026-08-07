package config

import "strings"

// Alias is one K9s aliases.yaml entry. Target is K9s' GVR-or-alias string,
// for example "apps/v1/deployments" or another configured alias.
type Alias struct {
	Name   string
	Target string
}

// Hotkey is one K9s hotKeys entry. Shortcut corresponds to K9s' shortCut
// YAML spelling; the Go name is normalized for callers.
type Hotkey struct {
	Name        string
	Shortcut    string
	Override    bool
	Description string
	Command     string
	KeepHistory bool
}

// Plugin is the native representation of a K9s plugin declaration. Confirm
// remains a pointer because K9s distinguishes an omitted confirm value from
// an explicit false value.
type Plugin struct {
	Name        string
	Scopes      []string
	Shortcut    string
	Override    bool
	Description string
	Command     string
	Args        []string
	Background  bool
	Confirm     *bool
	Dangerous   bool
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
	Key        string
	Columns    []string
	SortColumn string
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
