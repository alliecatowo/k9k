package api

import (
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"

	"gopkg.in/yaml.v3"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

const (
	maxHelmHistoryRevisions      = 128
	maxHelmDecodedReleaseBytes   = 4 << 20
	maxHelmSensitiveContentBytes = 1 << 20
	maxHelmUpgradeChartBytes     = 8 << 20
	maxHelmUpgradeValuesBytes    = 1 << 20
	maxHelmRepositoryConfigBytes = 1 << 20
	helmSensitiveContentWarning  = "This release content can contain credentials, tokens, endpoints, or other production-sensitive values."
)

var helmSecretsGVR = schema.GroupVersionResource{Version: "v1", Resource: "secrets"}

var (
	// ErrHelmReleaseChanged is deliberately distinct from a Kubernetes API
	// error. It means the release changed after an operator opened its history,
	// so K9k must require a fresh review rather than applying an action to the
	// newer state.
	ErrHelmReleaseChanged = errors.New("Helm release changed since it was reviewed")
	ErrHelmReleaseUnsafe  = errors.New("Helm release is not in a lifecycle state K9k can safely mutate")
)

// helmHistory converts Helm v3's standard Secret labels into a stable,
// metadata-only history. It deliberately does not decode a release payload;
// the separately gated helmInspect path verifies a selected revision before
// reading its bounded, opt-in sensitive fields.
func (s *Server) helmHistory(ctx context.Context, namespace, release string) (HelmReleaseHistory, error) {
	secrets, err := s.cluster.List(ctx, helmSecretsGVR, namespace, true, "owner=helm", "")
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

// HelmReleaseInspectionRequest names an already-discovered Helm storage
// Secret. The server verifies every identity component again before decoding
// its opaque release payload, so a caller cannot use this read path to expose
// arbitrary Kubernetes Secret data.
type HelmReleaseInspectionRequest struct {
	Namespace            string `json:"namespace"`
	Release              string `json:"release"`
	StorageName          string `json:"storageName"`
	Revision             int    `json:"revision"`
	IncludeSensitive     bool   `json:"includeSensitive"`
	AcknowledgeSensitive bool   `json:"acknowledgeSensitive"`
}

func validateHelmInspectionParams(params HelmReleaseInspectionRequest) (HelmReleaseInspectionRequest, error) {
	namespace, release, err := validateHelmHistoryParams(params.Namespace, params.Release)
	if err != nil {
		return HelmReleaseInspectionRequest{}, err
	}
	params.Namespace, params.Release = namespace, release
	params.StorageName = strings.TrimSpace(params.StorageName)
	if params.Namespace == "" {
		return HelmReleaseInspectionRequest{}, fmt.Errorf("namespace is required for Helm Secret storage")
	}
	if params.StorageName == "" || len(params.StorageName) > 253 {
		return HelmReleaseInspectionRequest{}, fmt.Errorf("a valid Helm storage name is required")
	}
	if params.Revision < 1 {
		return HelmReleaseInspectionRequest{}, fmt.Errorf("a positive Helm revision is required")
	}
	if params.IncludeSensitive && !params.AcknowledgeSensitive {
		return HelmReleaseInspectionRequest{}, fmt.Errorf("set acknowledgeSensitive: true before reading sensitive Helm content")
	}
	return params, nil
}

func validateHelmRollbackParams(params HelmRollbackRequest) (HelmRollbackRequest, error) {
	namespace, release, err := validateHelmHistoryParams(params.Namespace, params.Release)
	if err != nil {
		return HelmRollbackRequest{}, err
	}
	params.Namespace, params.Release = namespace, release
	params.TargetStorageName = strings.TrimSpace(params.TargetStorageName)
	params.ExpectedStorageName = strings.TrimSpace(params.ExpectedStorageName)
	if params.Namespace == "" {
		return HelmRollbackRequest{}, fmt.Errorf("namespace is required for Helm Secret storage")
	}
	if params.TargetRevision < 1 || params.ExpectedRevision < 1 {
		return HelmRollbackRequest{}, fmt.Errorf("targetRevision and expectedRevision must be positive")
	}
	if params.TargetStorageName == "" || params.ExpectedStorageName == "" || len(params.TargetStorageName) > 253 || len(params.ExpectedStorageName) > 253 {
		return HelmRollbackRequest{}, fmt.Errorf("valid Helm storage names are required")
	}
	if params.TargetRevision >= params.ExpectedRevision {
		return HelmRollbackRequest{}, fmt.Errorf("targetRevision must be an earlier revision than the reviewed release")
	}
	return params, nil
}

func validateHelmUninstallParams(params HelmUninstallRequest) (HelmUninstallRequest, error) {
	namespace, release, err := validateHelmHistoryParams(params.Namespace, params.Release)
	if err != nil {
		return HelmUninstallRequest{}, err
	}
	params.Namespace, params.Release = namespace, release
	params.ExpectedStorageName = strings.TrimSpace(params.ExpectedStorageName)
	if params.Namespace == "" {
		return HelmUninstallRequest{}, fmt.Errorf("namespace is required for Helm Secret storage")
	}
	if params.ExpectedRevision < 1 || params.ExpectedStorageName == "" || len(params.ExpectedStorageName) > 253 {
		return HelmUninstallRequest{}, fmt.Errorf("a valid current Helm storage revision is required")
	}
	return params, nil
}

func validateHelmUpgradeParams(params HelmUpgradeRequest, requirePlanDigest bool) (HelmUpgradeRequest, error) {
	namespace, release, err := validateHelmHistoryParams(params.Namespace, params.Release)
	if err != nil {
		return HelmUpgradeRequest{}, err
	}
	params.Namespace, params.Release = namespace, release
	params.ExpectedStorageName = strings.TrimSpace(params.ExpectedStorageName)
	params.ValuesMode = strings.ToLower(strings.TrimSpace(params.ValuesMode))
	params.PlanDigest = strings.ToLower(strings.TrimSpace(params.PlanDigest))
	if params.Namespace == "" || params.ExpectedRevision < 1 || params.ExpectedStorageName == "" || len(params.ExpectedStorageName) > 253 {
		return HelmUpgradeRequest{}, fmt.Errorf("namespace and a valid current Helm storage revision are required")
	}
	if params.ValuesMode == "" {
		params.ValuesMode = "reset"
	}
	switch params.ValuesMode {
	case "reset", "reuse", "reset-then-reuse":
	default:
		return HelmUpgradeRequest{}, fmt.Errorf("valuesMode must be reset, reuse, or reset-then-reuse")
	}
	if len(params.ValuesYAML) > maxHelmUpgradeValuesBytes {
		return HelmUpgradeRequest{}, fmt.Errorf("valuesYAML exceeds the %d-byte limit", maxHelmUpgradeValuesBytes)
	}
	if len(params.ChartArchiveBase64) == 0 || len(params.ChartArchiveBase64) > base64.StdEncoding.EncodedLen(maxHelmUpgradeChartBytes) {
		return HelmUpgradeRequest{}, fmt.Errorf("chartArchiveBase64 must contain a packaged chart no larger than %d bytes", maxHelmUpgradeChartBytes)
	}
	archive, err := base64.StdEncoding.DecodeString(params.ChartArchiveBase64)
	if err != nil || len(archive) == 0 || len(archive) > maxHelmUpgradeChartBytes {
		return HelmUpgradeRequest{}, fmt.Errorf("chartArchiveBase64 is not a valid bounded packaged chart")
	}
	if requirePlanDigest {
		if len(params.PlanDigest) != sha256.Size*2 {
			return HelmUpgradeRequest{}, fmt.Errorf("a planDigest from helm.upgrade.plan is required")
		}
		if _, err := hex.DecodeString(params.PlanDigest); err != nil {
			return HelmUpgradeRequest{}, fmt.Errorf("planDigest must be hexadecimal")
		}
		if !strings.EqualFold(params.PlanDigest, helmUpgradeDigest(params, archive)) {
			return HelmUpgradeRequest{}, fmt.Errorf("planDigest does not match this exact chart, values, and release revision")
		}
	}
	return params, nil
}

func helmUpgradeDigest(params HelmUpgradeRequest, archive []byte) string {
	hash := sha256.New()
	for _, value := range [][]byte{[]byte(params.Namespace), []byte{0}, []byte(params.Release), []byte{0}, []byte(params.ExpectedStorageName), []byte{0}, []byte(strconv.Itoa(params.ExpectedRevision)), []byte{0}, []byte(params.ValuesMode), []byte{0}, []byte(params.ValuesYAML), []byte{0}, archive} {
		_, _ = hash.Write(value)
	}
	return fmt.Sprintf("%x", hash.Sum(nil))
}

// inspectHelmRepositoryConfig parses a user-selected repositories.yaml as a
// metadata-only document. It deliberately ignores every credential-related
// field supported by Helm's on-disk format and never performs a network call.
func inspectHelmRepositoryConfig(document string) (HelmRepositoryInspection, error) {
	if len(document) == 0 || len(document) > maxHelmRepositoryConfigBytes {
		return HelmRepositoryInspection{}, fmt.Errorf("repository configuration must be between 1 byte and %d bytes", maxHelmRepositoryConfigBytes)
	}
	var parsed struct {
		APIVersion   string `yaml:"apiVersion"`
		Repositories []struct {
			Name string `yaml:"name"`
			URL  string `yaml:"url"`
		} `yaml:"repositories"`
	}
	if err := yaml.Unmarshal([]byte(document), &parsed); err != nil {
		return HelmRepositoryInspection{}, fmt.Errorf("parse Helm repository configuration: %w", err)
	}
	result := HelmRepositoryInspection{Repositories: []HelmRepositorySource{}, Warnings: []string{}}
	seen := make(map[string]struct{}, len(parsed.Repositories))
	for _, candidate := range parsed.Repositories {
		name, rawURL := strings.TrimSpace(candidate.Name), strings.TrimSpace(candidate.URL)
		if name == "" || rawURL == "" {
			result.Warnings = append(result.Warnings, "Ignored a repository entry without both a name and URL.")
			continue
		}
		parsedURL, err := url.Parse(rawURL)
		if err != nil || parsedURL.Host == "" || (parsedURL.Scheme != "https" && parsedURL.Scheme != "http") || parsedURL.User != nil {
			result.Warnings = append(result.Warnings, fmt.Sprintf("Ignored repository %q because its URL is not a credential-free HTTP(S) endpoint.", name))
			continue
		}
		key := strings.ToLower(name) + "\x00" + rawURL
		if _, exists := seen[key]; exists {
			continue
		}
		seen[key] = struct{}{}
		result.Repositories = append(result.Repositories, HelmRepositorySource{Name: name, URL: rawURL})
	}
	sort.Slice(result.Repositories, func(i, j int) bool { return result.Repositories[i].Name < result.Repositories[j].Name })
	return result, nil
}

// verifyHelmCurrentRevision closes the UI-to-action race as far as Kubernetes
// permits. Helm itself has no resourceVersion precondition for lifecycle
// operations, so the helper reloads Secret-backed history and requires the
// exact latest storage revision that the native sheet showed the operator.
func (s *Server) verifyHelmCurrentRevision(ctx context.Context, namespace, release, storageName string, revision int) error {
	history, err := s.helmHistory(ctx, namespace, release)
	if err != nil {
		return err
	}
	var current *HelmReleaseRevision
	for i := range history.Revisions {
		if history.Revisions[i].Revision > 0 {
			current = &history.Revisions[i]
			break
		}
	}
	if current == nil || current.Revision != revision || current.StorageName != storageName {
		return fmt.Errorf("%w; refresh Helm history before retrying", ErrHelmReleaseChanged)
	}
	switch strings.ToLower(strings.TrimSpace(current.Status)) {
	case "uninstalled", "uninstalling", "pending-install", "pending-upgrade", "pending-rollback":
		return fmt.Errorf("%w: current status is %q", ErrHelmReleaseUnsafe, current.Status)
	}
	// List metadata is not sufficient to trust an opaque Secret reference.
	// Reuse the inspection identity gate without returning its potentially
	// sensitive payload to the lifecycle operation.
	_, err = s.helmInspect(ctx, HelmReleaseInspectionRequest{
		Namespace: namespace, Release: release, StorageName: storageName, Revision: revision,
	})
	return err
}

func (s *Server) verifyHelmRollback(ctx context.Context, request HelmRollbackRequest) error {
	if err := s.verifyHelmCurrentRevision(ctx, request.Namespace, request.Release, request.ExpectedStorageName, request.ExpectedRevision); err != nil {
		return err
	}
	_, err := s.helmInspect(ctx, HelmReleaseInspectionRequest{
		Namespace: request.Namespace, Release: request.Release, StorageName: request.TargetStorageName, Revision: request.TargetRevision,
	})
	return err
}

// checkHelmStorageAccess checks the Secret-driver verbs that Helm needs before
// starting a lifecycle operation. Chart resources and hooks can vary by
// release; those are still enforced authoritatively by the API server during
// the SDK operation and reported verbatim if unavailable.
func (s *Server) checkHelmStorageAccess(ctx context.Context, namespace string, verbs ...string) *operationError {
	for _, verb := range verbs {
		review, err := s.cluster.CheckAccess(ctx, AccessCheck{Verb: verb, Resource: "secrets", Namespace: namespace})
		if err != nil {
			return kubeError(err)
		}
		if !review.Allowed {
			reason := strings.TrimSpace(review.Reason)
			if reason == "" {
				reason = "Kubernetes did not authorize this Helm storage action"
			}
			return &operationError{code: "forbidden", err: fmt.Errorf("Helm lifecycle requires secrets.%s in namespace %q: %s", verb, namespace, reason)}
		}
	}
	return nil
}

// helmInspect reads Helm's default v3 Secret driver directly through
// client-go. It does not call Helm, invoke a shell, or mutate release storage.
func (s *Server) helmInspect(ctx context.Context, request HelmReleaseInspectionRequest) (HelmReleaseInspection, error) {
	secret, err := s.cluster.Get(ctx, helmSecretsGVR, request.Namespace, request.StorageName, true)
	if err != nil {
		return HelmReleaseInspection{}, err
	}
	if secret == nil {
		return HelmReleaseInspection{}, fmt.Errorf("Helm storage Secret was not found")
	}
	if secret.GetName() != request.StorageName || secret.GetNamespace() != request.Namespace {
		return HelmReleaseInspection{}, fmt.Errorf("Helm storage Secret identity no longer matches the selected revision")
	}
	labels := secret.GetLabels()
	if labels["owner"] != "helm" || helmReleaseNameFromMetadata(labels, secret.GetAnnotations()) != request.Release {
		return HelmReleaseInspection{}, fmt.Errorf("requested Secret is not Helm storage for release %q", request.Release)
	}
	if revision := helmRevisionFromLabels(labels); revision != request.Revision {
		return HelmReleaseInspection{}, fmt.Errorf("requested Secret does not match Helm revision %d", request.Revision)
	}

	payload, err := decodeHelmStorageSecret(secret)
	if err != nil {
		return HelmReleaseInspection{}, err
	}
	if payload.Name != request.Release || (payload.Version != 0 && payload.Version != request.Revision) {
		return HelmReleaseInspection{}, fmt.Errorf("Helm storage payload identity does not match the selected revision")
	}
	if payload.Namespace != "" && payload.Namespace != request.Namespace {
		return HelmReleaseInspection{}, fmt.Errorf("Helm storage payload namespace does not match the selected release")
	}

	metadata := payload.Chart.Metadata
	if metadata == nil {
		return HelmReleaseInspection{}, fmt.Errorf("Helm release has no chart metadata")
	}
	inspection := HelmReleaseInspection{
		Release: request.Release, Namespace: request.Namespace,
		Revision:                  HelmReleaseRevision{Revision: request.Revision, Status: helmStatusFromLabels(labels), StorageName: secret.GetName(), CreatedAt: secret.GetCreationTimestamp().Time},
		Chart:                     chartMetadataProjection(metadata),
		SensitiveContentAvailable: payload.Manifest != "" || payload.Info.Notes != "" || len(payload.Config) > 0,
	}
	if request.IncludeSensitive {
		inspection.Sensitive, err = payload.sensitiveContents()
		if err != nil {
			return HelmReleaseInspection{}, err
		}
	}
	return inspection, nil
}

func helmReleaseNameFromMetadata(labels, annotations map[string]string) string {
	if name := strings.TrimSpace(labels["name"]); name != "" {
		return name
	}
	return strings.TrimSpace(annotations["meta.helm.sh/release-name"])
}

func helmRevisionFromLabels(labels map[string]string) int {
	revision, err := strconv.Atoi(strings.TrimSpace(labels["version"]))
	if err != nil || revision < 1 {
		return 0
	}
	return revision
}

func helmStatusFromLabels(labels map[string]string) string {
	if status := strings.TrimSpace(labels["status"]); status != "" {
		return status
	}
	return "unknown"
}

// helmReleasePayload models only the stable JSON fields Helm's storage
// driver encodes. We intentionally do not deserialize templates, raw chart
// files, hooks, or Kubernetes runtime objects from the opaque archive.
type helmReleasePayload struct {
	Name      string                `json:"name"`
	Namespace string                `json:"namespace"`
	Version   int                   `json:"version"`
	Chart     helmStoredChart       `json:"chart"`
	Config    map[string]any        `json:"config"`
	Manifest  string                `json:"manifest"`
	Info      helmStoredReleaseInfo `json:"info"`
}

type helmStoredChart struct {
	Metadata *helmStoredChartMetadata `json:"metadata"`
}

type helmStoredReleaseInfo struct {
	Notes string `json:"notes"`
}

type helmStoredChartMetadata struct {
	Name        string   `json:"name"`
	Version     string   `json:"version"`
	AppVersion  string   `json:"appVersion"`
	APIVersion  string   `json:"apiVersion"`
	Description string   `json:"description"`
	Type        string   `json:"type"`
	Home        string   `json:"home"`
	Icon        string   `json:"icon"`
	KubeVersion string   `json:"kubeVersion"`
	Deprecated  bool     `json:"deprecated"`
	Sources     []string `json:"sources"`
	Keywords    []string `json:"keywords"`
}

func chartMetadataProjection(metadata *helmStoredChartMetadata) HelmChartMetadata {
	return HelmChartMetadata{
		Name: metadata.Name, Version: metadata.Version, AppVersion: metadata.AppVersion, APIVersion: metadata.APIVersion,
		Description: metadata.Description, Type: metadata.Type, Home: metadata.Home, Icon: metadata.Icon,
		KubeVersion: metadata.KubeVersion, Deprecated: metadata.Deprecated,
		Sources: append([]string{}, metadata.Sources...), Keywords: append([]string{}, metadata.Keywords...),
	}
}

func decodeHelmStorageSecret(secret *unstructured.Unstructured) (helmReleasePayload, error) {
	encodedSecretData, found, err := unstructured.NestedString(secret.Object, "data", "release")
	if err != nil || !found || strings.TrimSpace(encodedSecretData) == "" {
		return helmReleasePayload{}, fmt.Errorf("Helm storage Secret has no release payload")
	}
	// Kubernetes serializes Secret data as base64 JSON. Helm then stores its
	// own base64 release envelope inside that byte sequence, so two decodes are
	// required for dynamic/unstructured client-go reads.
	helmEnvelope, err := base64.StdEncoding.DecodeString(encodedSecretData)
	if err != nil {
		return helmReleasePayload{}, fmt.Errorf("decode Kubernetes Helm Secret data: %w", err)
	}
	payload, err := base64.StdEncoding.DecodeString(string(helmEnvelope))
	if err != nil {
		return helmReleasePayload{}, fmt.Errorf("decode Helm release envelope: %w", err)
	}
	if len(payload) >= 3 && bytes.Equal(payload[:3], []byte{0x1f, 0x8b, 0x08}) {
		reader, err := gzip.NewReader(bytes.NewReader(payload))
		if err != nil {
			return helmReleasePayload{}, fmt.Errorf("open Helm release compression: %w", err)
		}
		decompressed, readErr := readHelmReleaseBounded(reader)
		closeErr := reader.Close()
		if readErr != nil {
			return helmReleasePayload{}, readErr
		}
		if closeErr != nil {
			return helmReleasePayload{}, fmt.Errorf("close Helm release compression: %w", closeErr)
		}
		payload = decompressed
	}
	if len(payload) > maxHelmDecodedReleaseBytes {
		return helmReleasePayload{}, fmt.Errorf("Helm release payload exceeds the %d-byte inspection limit", maxHelmDecodedReleaseBytes)
	}
	var result helmReleasePayload
	if err := json.Unmarshal(payload, &result); err != nil {
		return helmReleasePayload{}, fmt.Errorf("decode Helm release payload: %w", err)
	}
	return result, nil
}

func readHelmReleaseBounded(reader io.Reader) ([]byte, error) {
	data, err := io.ReadAll(io.LimitReader(reader, maxHelmDecodedReleaseBytes+1))
	if err != nil {
		return nil, fmt.Errorf("read Helm release payload: %w", err)
	}
	if len(data) > maxHelmDecodedReleaseBytes {
		return nil, fmt.Errorf("Helm release payload exceeds the %d-byte inspection limit", maxHelmDecodedReleaseBytes)
	}
	return data, nil
}

func (payload helmReleasePayload) sensitiveContents() (*HelmSensitiveContents, error) {
	values := ""
	if len(payload.Config) > 0 {
		data, err := json.MarshalIndent(payload.Config, "", "  ")
		if err != nil {
			return nil, fmt.Errorf("encode Helm release values for inspection: %w", err)
		}
		values = string(data)
	}
	manifest, manifestTruncated := truncateHelmText(payload.Manifest)
	notes, notesTruncated := truncateHelmText(payload.Info.Notes)
	values, valuesTruncated := truncateHelmText(values)
	return &HelmSensitiveContents{Warning: helmSensitiveContentWarning, Manifest: manifest, ManifestTruncated: manifestTruncated, Notes: notes, NotesTruncated: notesTruncated, ValuesJSON: values, ValuesTruncated: valuesTruncated}, nil
}

func truncateHelmText(value string) (string, bool) {
	if len(value) <= maxHelmSensitiveContentBytes {
		return value, false
	}
	end := maxHelmSensitiveContentBytes
	for end > 0 && !utf8.ValidString(value[:end]) {
		end--
	}
	return value[:end], true
}
