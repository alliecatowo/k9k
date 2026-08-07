package config

import (
	"errors"
	"strings"
	"testing"
)

func TestParseAliases(t *testing.T) {
	aliases, err := ParseAliases([]byte("aliases:\n  dp: apps/v1/deployments\n  sec: v1/secrets\n"))
	if err != nil {
		t.Fatalf("ParseAliases() error = %v", err)
	}
	if got := aliases["dp"]; got != (Alias{Name: "dp", Target: "apps/v1/deployments"}) {
		t.Fatalf("deployment alias = %#v", got)
	}
	if got := aliases["sec"].Target; got != "v1/secrets" {
		t.Fatalf("secret target = %q", got)
	}
}

func TestParseHotkeys(t *testing.T) {
	hotkeys, err := ParseHotkeys([]byte(`hotKeys:
  pods:
    shortCut: shift-0
    description: Launch pod view
    command: pods
    keepHistory: true
    override: true
`))
	if err != nil {
		t.Fatalf("ParseHotkeys() error = %v", err)
	}
	got := hotkeys["pods"]
	if got.Shortcut != "shift-0" || got.Command != "pods" || !got.KeepHistory || !got.Override {
		t.Fatalf("hotkey = %#v", got)
	}
}

func TestParsePluginsNormalizesK9sFormats(t *testing.T) {
	t.Run("wrapped", func(t *testing.T) {
		plugins, err := ParsePlugins([]byte(`plugins:
  drain:
    shortCut: shift-d
    description: Drain the selected node
    scopes: [no, all]
    command: kubectl
    args: [drain, 42, --ignore-daemonsets]
    background: true
    confirm: false
    dangerous: true
`), "plugins.yaml")
		if err != nil {
			t.Fatalf("ParsePlugins() error = %v", err)
		}
		plugin := plugins["drain"]
		if plugin.Name != "drain" || !plugin.Background || !plugin.Dangerous || plugin.Confirm == nil || *plugin.Confirm {
			t.Fatalf("plugin = %#v", plugin)
		}
		if got, want := strings.Join(plugin.Args, ","), "drain,42,--ignore-daemonsets"; got != want {
			t.Fatalf("args = %q, want %q", got, want)
		}
		if !plugin.AppliesTo("po") || !plugin.AppliesTo("no") || plugin.ShouldConfirm() {
			t.Fatalf("scope or confirmation behavior incorrect: %#v", plugin)
		}
	})

	t.Run("single", func(t *testing.T) {
		plugins, err := ParsePlugins([]byte(`shortCut: shift-r
description: Restart
scopes: [dp]
command: kubectl
args: [rollout, restart]
confirm: true
`), "/tmp/restart.yaml")
		if err != nil {
			t.Fatalf("ParsePlugins() error = %v", err)
		}
		plugin, ok := plugins["restart"]
		if !ok || !plugin.ShouldConfirm() || plugin.Name != "restart" {
			t.Fatalf("single plugin = %#v", plugins)
		}
	})

	t.Run("multi", func(t *testing.T) {
		plugins, err := ParsePlugins([]byte(`logs:
  shortCut: l
  description: Logs
  scopes: [po]
  command: kubectl
other:
  shortCut: o
  description: Other
  scopes: [all]
  command: echo
`), "ignored.yaml")
		if err != nil {
			t.Fatalf("ParsePlugins() error = %v", err)
		}
		if len(plugins) != 2 || !plugins["other"].AppliesTo("anything") {
			t.Fatalf("multi plugins = %#v", plugins)
		}
	})
}

func TestParsePluginsRejectsInvalidRequiredFieldsAndArgs(t *testing.T) {
	_, err := ParsePlugins([]byte(`plugins:
  invalid:
    shortCut: i
    description: Invalid
    scopes: [po]
    command: echo
    args: [[not, scalar]]
`), "plugins.yaml")
	if err == nil || !strings.Contains(err.Error(), "args entries") {
		t.Fatalf("ParsePlugins() error = %v, want invalid args error", err)
	}

	_, err = ParsePlugins([]byte(`plugins:
  invalid:
    shortCut: i
    description: Invalid
    command: echo
`), "plugins.yaml")
	if err == nil || !strings.Contains(err.Error(), "scopes is required") {
		t.Fatalf("ParsePlugins() error = %v, want missing scopes error", err)
	}
}

func TestParseViewsAndSort(t *testing.T) {
	views, err := ParseViews([]byte(`views:
  v1/pods:
    columns: [NAMESPACE, NAME, AGE, IP]
    sortColumn: NAME:asc
  v1/pods@default:
    columns: [NAME, IP]
`))
	if err != nil {
		t.Fatalf("ParseViews() error = %v", err)
	}
	pods := views["v1/pods"]
	if got, want := strings.Join(pods.Columns, ","), "NAMESPACE,NAME,AGE,IP"; got != want {
		t.Fatalf("columns = %q, want %q", got, want)
	}
	column, ascending, err := pods.Sort()
	if err != nil || column != "NAME" || !ascending {
		t.Fatalf("Sort() = (%q, %t, %v)", column, ascending, err)
	}
	if _, _, err := views["v1/pods@default"].Sort(); !errors.Is(err, ErrNoSortColumn) {
		t.Fatalf("missing sort error = %v", err)
	}
}

func TestParseViewsRequiresColumns(t *testing.T) {
	_, err := ParseViews([]byte("views:\n  v1/pods:\n    sortColumn: NAME:asc\n"))
	if err == nil || !strings.Contains(err.Error(), "columns is required") {
		t.Fatalf("ParseViews() error = %v, want missing columns error", err)
	}
}

func TestParseJumps(t *testing.T) {
	jumps, err := ParseJumps([]byte("jumps:\n  stable.example.io/v1/widgets:\n    targetGVR: v1/pods\n    labelSelector: app={{.metadata.labels.app}}\n    targetNamespace: all\n"))
	if err != nil {
		t.Fatal(err)
	}
	got := jumps["stable.example.io/v1/widgets"]
	if got.TargetGVR != "v1/pods" || got.LabelSelector != "app={{.metadata.labels.app}}" || got.TargetNamespace != "all" {
		t.Errorf("jump = %#v", got)
	}
	if _, err := ParseJumps([]byte("jumps:\n  v1/pods: {}\n")); err == nil {
		t.Fatal("expected missing target error")
	}
}
