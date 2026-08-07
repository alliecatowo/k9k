package kube

import (
	"context"
	"fmt"
	"sort"
	"strings"

	"github.com/k9k-app/k9k/backend/internal/api"
	rbacv1 "k8s.io/api/rbac/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
)

// These ceilings keep an explanatory RBAC read useful on clusters with broad
// group bindings without turning it into an unbounded cluster inventory. A
// ceiling is always represented in the response, never silently omitted.
const (
	effectiveRBACBindingLimit = 512
	effectiveRBACRoleLimit    = 128
)

// EffectiveRBAC resolves the RoleBinding/ClusterRoleBinding declarations that
// directly name the requested subject and copies the current rules from their
// Role or ClusterRole. It deliberately does not create a SubjectAccessReview:
// that would impersonate an arbitrary subject, and it cannot account for
// external authorizers or group membership anyway.
func (c *Cluster) EffectiveRBAC(ctx context.Context, request api.EffectiveRBACRequest) (api.EffectiveRBACAnalysis, error) {
	c.mu.RLock()
	typed := c.typed
	c.mu.RUnlock()
	if typed == nil {
		return api.EffectiveRBACAnalysis{}, fmt.Errorf("no usable Kubernetes context is selected")
	}

	analysis := api.EffectiveRBACAnalysis{
		Subject:  api.EffectiveRBACSubject{Kind: request.SubjectKind, Name: request.SubjectName, Namespace: request.SubjectNamespace},
		Bindings: []api.EffectiveRBACBinding{},
		Warnings: []string{
			"Static RBAC explanation only: it is not an authorization decision. Use Check Access for the active kubeconfig identity.",
			"External authorizers, admission policy, and User/Group membership are not evaluated.",
		},
	}

	roleBindings, roleBindingTruncated, roleBindingWarning := listMatchingRoleBindings(ctx, typed, request)
	if roleBindingWarning != "" {
		analysis.Warnings = append(analysis.Warnings, roleBindingWarning)
	}
	clusterRoleBindings, clusterRoleBindingTruncated, clusterRoleBindingWarning := listMatchingClusterRoleBindings(ctx, typed, request)
	if clusterRoleBindingWarning != "" {
		analysis.Warnings = append(analysis.Warnings, clusterRoleBindingWarning)
	}
	analysis.Truncated = roleBindingTruncated || clusterRoleBindingTruncated
	if analysis.Truncated {
		analysis.Warnings = append(analysis.Warnings, fmt.Sprintf("Binding inspection reached the %d-object limit; matching grants beyond that boundary are not shown.", effectiveRBACBindingLimit))
	}

	bindings := make([]rbacBindingReference, 0, len(roleBindings)+len(clusterRoleBindings))
	for _, binding := range roleBindings {
		bindings = append(bindings, rbacBindingReference{kind: "RoleBinding", namespace: binding.Namespace, name: binding.Name, roleKind: binding.RoleRef.Kind, roleName: binding.RoleRef.Name})
	}
	for _, binding := range clusterRoleBindings {
		bindings = append(bindings, rbacBindingReference{kind: "ClusterRoleBinding", name: binding.Name, roleKind: binding.RoleRef.Kind, roleName: binding.RoleRef.Name})
	}
	sort.Slice(bindings, func(i, j int) bool {
		return strings.Join([]string{bindings[i].kind, bindings[i].namespace, bindings[i].name}, "\x00") < strings.Join([]string{bindings[j].kind, bindings[j].namespace, bindings[j].name}, "\x00")
	})

	roles := make(map[string]roleResolution)
	for _, binding := range bindings {
		key := strings.Join([]string{binding.roleKind, binding.namespace, binding.roleName}, "\x00")
		resolution, exists := roles[key]
		if !exists {
			if len(roles) >= effectiveRBACRoleLimit {
				resolution = roleResolution{warning: fmt.Sprintf("Role resolution reached the %d-role limit; rules for this binding are not shown.", effectiveRBACRoleLimit)}
				analysis.Truncated = true
			} else {
				resolution = resolveRBACRole(ctx, typed, binding)
			}
			roles[key] = resolution
		}
		analysis.Bindings = append(analysis.Bindings, api.EffectiveRBACBinding{
			Kind: binding.kind, Name: binding.name, Namespace: binding.namespace,
			RoleKind: binding.roleKind, RoleName: binding.roleName,
			Rules: resolution.rules, RoleResolved: resolution.warning == "", Warning: resolution.warning,
		})
	}
	if len(roles) >= effectiveRBACRoleLimit {
		analysis.Warnings = append(analysis.Warnings, fmt.Sprintf("Role resolution is capped at %d distinct role references.", effectiveRBACRoleLimit))
	}
	return analysis, nil
}

type rbacBindingReference struct {
	kind, namespace, name, roleKind, roleName string
}

type roleResolution struct {
	rules   []api.EffectiveRBACRule
	warning string
}

func listMatchingRoleBindings(ctx context.Context, typed kubernetes.Interface, request api.EffectiveRBACRequest) ([]rbacv1.RoleBinding, bool, string) {
	namespace := request.BindingNamespace
	if request.SubjectKind == "ServiceAccount" {
		namespace = request.SubjectNamespace
	}
	items, truncated, err := listRoleBindingsBounded(ctx, typed, namespace)
	if err != nil {
		return nil, false, fmt.Sprintf("Could not list RoleBindings%s: %v. Namespaced grants may be missing.", displayRBACScope(namespace), err)
	}
	result := make([]rbacv1.RoleBinding, 0, len(items))
	for _, item := range items {
		if bindingMentionsSubject(item.Subjects, request, item.Namespace) {
			result = append(result, item)
		}
	}
	return result, truncated, ""
}

func listMatchingClusterRoleBindings(ctx context.Context, typed kubernetes.Interface, request api.EffectiveRBACRequest) ([]rbacv1.ClusterRoleBinding, bool, string) {
	items, truncated, err := listClusterRoleBindingsBounded(ctx, typed)
	if err != nil {
		return nil, false, fmt.Sprintf("Could not list ClusterRoleBindings: %v. Cluster-wide grants may be missing.", err)
	}
	result := make([]rbacv1.ClusterRoleBinding, 0, len(items))
	for _, item := range items {
		if bindingMentionsSubject(item.Subjects, request, "") {
			result = append(result, item)
		}
	}
	return result, truncated, ""
}

func listRoleBindingsBounded(ctx context.Context, typed kubernetes.Interface, namespace string) ([]rbacv1.RoleBinding, bool, error) {
	result := make([]rbacv1.RoleBinding, 0)
	continueToken := ""
	for len(result) < effectiveRBACBindingLimit {
		remaining := int64(effectiveRBACBindingLimit - len(result))
		page, err := typed.RbacV1().RoleBindings(namespace).List(ctx, metav1.ListOptions{Limit: remaining, Continue: continueToken})
		if err != nil {
			return nil, false, err
		}
		result = append(result, page.Items...)
		if page.Continue == "" {
			return result, false, nil
		}
		continueToken = page.Continue
	}
	return result, true, nil
}

func listClusterRoleBindingsBounded(ctx context.Context, typed kubernetes.Interface) ([]rbacv1.ClusterRoleBinding, bool, error) {
	result := make([]rbacv1.ClusterRoleBinding, 0)
	continueToken := ""
	for len(result) < effectiveRBACBindingLimit {
		remaining := int64(effectiveRBACBindingLimit - len(result))
		page, err := typed.RbacV1().ClusterRoleBindings().List(ctx, metav1.ListOptions{Limit: remaining, Continue: continueToken})
		if err != nil {
			return nil, false, err
		}
		result = append(result, page.Items...)
		if page.Continue == "" {
			return result, false, nil
		}
		continueToken = page.Continue
	}
	return result, true, nil
}

func bindingMentionsSubject(subjects []rbacv1.Subject, request api.EffectiveRBACRequest, defaultNamespace string) bool {
	for _, subject := range subjects {
		if subject.Kind != request.SubjectKind || subject.Name != request.SubjectName {
			continue
		}
		if request.SubjectKind != "ServiceAccount" {
			return true
		}
		namespace := subject.Namespace
		if namespace == "" {
			namespace = defaultNamespace
		}
		if namespace == request.SubjectNamespace {
			return true
		}
	}
	return false
}

func resolveRBACRole(ctx context.Context, typed kubernetes.Interface, binding rbacBindingReference) roleResolution {
	switch binding.roleKind {
	case "Role":
		if binding.namespace == "" {
			return roleResolution{warning: "RoleBinding references a namespaced Role without a namespace."}
		}
		role, err := typed.RbacV1().Roles(binding.namespace).Get(ctx, binding.roleName, metav1.GetOptions{})
		if err != nil {
			return roleResolution{warning: fmt.Sprintf("Could not read referenced Role: %v", err)}
		}
		return roleResolution{rules: effectiveRBACRules(role.Rules)}
	case "ClusterRole":
		role, err := typed.RbacV1().ClusterRoles().Get(ctx, binding.roleName, metav1.GetOptions{})
		if err != nil {
			return roleResolution{warning: fmt.Sprintf("Could not read referenced ClusterRole: %v", err)}
		}
		return roleResolution{rules: effectiveRBACRules(role.Rules)}
	default:
		return roleResolution{warning: fmt.Sprintf("Unsupported roleRef kind %q; expected Role or ClusterRole.", binding.roleKind)}
	}
}

func effectiveRBACRules(rules []rbacv1.PolicyRule) []api.EffectiveRBACRule {
	result := make([]api.EffectiveRBACRule, 0, len(rules))
	for _, rule := range rules {
		result = append(result, api.EffectiveRBACRule{
			APIGroups: cloneSortedStrings(rule.APIGroups), Resources: cloneSortedStrings(rule.Resources), Verbs: cloneSortedStrings(rule.Verbs),
			ResourceNames: cloneSortedStrings(rule.ResourceNames), NonResourceURLs: cloneSortedStrings(rule.NonResourceURLs),
		})
	}
	sort.Slice(result, func(i, j int) bool {
		return strings.Join(result[i].Verbs, ",")+"\x00"+strings.Join(result[i].APIGroups, ",")+"\x00"+strings.Join(result[i].Resources, ",") < strings.Join(result[j].Verbs, ",")+"\x00"+strings.Join(result[j].APIGroups, ",")+"\x00"+strings.Join(result[j].Resources, ",")
	})
	return result
}

func cloneSortedStrings(values []string) []string {
	result := append([]string{}, values...)
	sort.Strings(result)
	return result
}

func displayRBACScope(namespace string) string {
	if namespace == "" {
		return " across namespaces"
	}
	return fmt.Sprintf(" in namespace %q", namespace)
}
