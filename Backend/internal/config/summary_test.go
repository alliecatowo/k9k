package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadSummaryTreatsMissingFilesAsEmptyConfiguration(t *testing.T) {
	directory := t.TempDir()
	summary, err := LoadSummary(directory)
	if err != nil {
		t.Fatal(err)
	}
	if summary.Directory != directory {
		t.Errorf("directory = %q, want %q", summary.Directory, directory)
	}
	if len(summary.Aliases) != 0 || len(summary.Hotkeys) != 0 || len(summary.Plugins) != 0 || len(summary.Views) != 0 {
		t.Errorf("missing configuration = %#v", summary)
	}
	for name, status := range summary.Files {
		if status.Present || status.Error != "" {
			t.Errorf("%s status = %#v, want missing without error", name, status)
		}
	}
}

func TestLoadSummaryReturnsValidSiblingsWhenOneFileIsInvalid(t *testing.T) {
	directory := t.TempDir()
	writeConfigFile(t, directory, aliasesFile, "aliases:\n  po: v1/pods\n  dp: apps/v1/deployments\n")
	writeConfigFile(t, directory, hotkeysFile, "hotKeys:\n  logs:\n    shortCut: l\n    description: Logs\n    command: logs\n")
	writeConfigFile(t, directory, pluginsFile, "plugins:\n  restart:\n    scopes: [deploy]\n    shortCut: shift-r\n    description: Restart\n    command: kubectl rollout restart deployment $NAME\n")
	writeConfigFile(t, directory, viewsFile, "views: [\n")

	summary, err := LoadSummary(directory)
	if err != nil {
		t.Fatal(err)
	}
	if got := summary.Aliases; len(got) != 2 || got[0].Name != "dp" || got[1].Name != "po" {
		t.Errorf("aliases = %#v", got)
	}
	if got := summary.Hotkeys; len(got) != 1 || got[0].Name != "logs" {
		t.Errorf("hotkeys = %#v", got)
	}
	if got := summary.Plugins; len(got) != 1 || got[0].Name != "restart" {
		t.Errorf("plugins = %#v", got)
	}
	if got := summary.Files["views"]; !got.Present || got.Error == "" {
		t.Errorf("views status = %#v, want present parse error", got)
	}
}

func writeConfigFile(t *testing.T, directory, name, contents string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(directory, name), []byte(contents), 0o600); err != nil {
		t.Fatal(err)
	}
}
