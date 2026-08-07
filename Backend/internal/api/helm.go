package api

import (
	"context"
	"fmt"
	"sort"
	"strconv"
	"strings"

	"k8s.io/apimachinery/pkg/runtime/schema"
)

const maxHelmHistoryRevisions = 128

// helmHistory converts Helm v3's standard Secret labels into a stable,
// metadata-only history. The release payload is intentionally never decoded:
// its contents can include chart values, credentials, and rendered objects.
func (s *Server) helmHistory(ctx context.Context, namespace, release string) (HelmReleaseHistory, error) {
	secrets, err := s.cluster.List(ctx, schema.GroupVersionResource{Version: "v1", Resource: "secrets"}, namespace, true, "owner=helm", "")
	if err != nil {
		return HelmReleaseHistory{}, err
	}

	history := HelmReleaseHistory{Release: release, Namespace: namespace, Revisions: []HelmReleaseRevision{}}
	for _, secret := range secrets {
		if helmReleaseName(secret) != release {
			continue
		}
		history.Total++
		history.Revisions = append(history.Revisions, HelmReleaseRevision{
			Revision:    helmRevision(secret),
			Status:      helmStatus(secret),
			StorageName: secret.Name,
			CreatedAt:   secret.CreatedAt,
			Age:         secret.Age,
		})
	}

	sort.SliceStable(history.Revisions, func(i, j int) bool {
		left, right := history.Revisions[i], history.Revisions[j]
		if left.Revision != right.Revision {
			// Valid revisions are newest-first; malformed zero revisions remain
			// inspectable at the end instead of masquerading as revision 0.
			if left.Revision == 0 || right.Revision == 0 {
				return right.Revision == 0
			}
			return left.Revision > right.Revision
		}
		return left.CreatedAt.After(right.CreatedAt)
	})
	if len(history.Revisions) > maxHelmHistoryRevisions {
		history.Revisions = history.Revisions[:maxHelmHistoryRevisions]
		history.Truncated = true
	}
	return history, nil
}

func helmReleaseName(secret ResourceSummary) string {
	if name := strings.TrimSpace(secret.Labels["name"]); name != "" {
		return name
	}
	metadata, _ := secret.Raw["metadata"].(map[string]any)
	annotations, _ := metadata["annotations"].(map[string]any)
	if name, _ := annotations["meta.helm.sh/release-name"].(string); strings.TrimSpace(name) != "" {
		return strings.TrimSpace(name)
	}
	return ""
}

func helmRevision(secret ResourceSummary) int {
	revision, err := strconv.Atoi(strings.TrimSpace(secret.Labels["version"]))
	if err != nil || revision < 1 {
		return 0
	}
	return revision
}

func helmStatus(secret ResourceSummary) string {
	if status := strings.TrimSpace(secret.Labels["status"]); status != "" {
		return status
	}
	return "unknown"
}

func validateHelmHistoryParams(namespace, release string) (string, string, error) {
	namespace, release = strings.TrimSpace(namespace), strings.TrimSpace(release)
	if release == "" {
		return "", "", fmt.Errorf("release is required")
	}
	if len(release) > 253 {
		return "", "", fmt.Errorf("release must not exceed 253 characters")
	}
	return namespace, release, nil
}
