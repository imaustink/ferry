package main

// FerryNodeClass: what a machine Karpenter provisions is made of.
//
// Karpenter splits "how many nodes and of what shape" (its own NodePool, which
// ferry does not define) from "what a node actually is", which is the provider's
// to describe. For ferry that is the node image, the shapes a machine may take,
// and what the Mac will commit in total.
//
// The limits live here rather than on Karpenter's NodePool on purpose. A
// NodePool limit is a policy about a workload; this is a fact about the machine
// the cluster is running on, and it applies no matter how many NodePools point
// at it.

import (
	"fmt"

	"github.com/awslabs/operatorpkg/status"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
)

const (
	group   = "ferry.dev"
	version = "v1alpha1"
)

var (
	SchemeGroupVersion = schema.GroupVersion{Group: group, Version: version}

	FerryNodeClassGVK = SchemeGroupVersion.WithKind("FerryNodeClass")
)

// Registered into client-go's global scheme, because that is the one
// Karpenter's operator resolves objects against. Without this the operator
// starts, prints its banner, and then panics deep inside NewControllers with
// "no kind is registered for the type main.FerryNodeClass" -- which is a long
// way from the missing line that caused it.
func init() {
	builder := runtime.NewSchemeBuilder(func(s *runtime.Scheme) error {
		s.AddKnownTypes(SchemeGroupVersion, &FerryNodeClass{}, &FerryNodeClassList{})
		metav1.AddToGroupVersion(s, SchemeGroupVersion)
		return nil
	})
	if err := builder.AddToScheme(clientgoscheme.Scheme); err != nil {
		panic(fmt.Sprintf("registering FerryNodeClass: %v", err))
	}
}

// +kubebuilder:object:root=true
type FerryNodeClass struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   FerryNodeClassSpec   `json:"spec,omitempty"`
	Status FerryNodeClassStatus `json:"status,omitempty"`
}

type FerryNodeClassSpec struct {
	// Image is the node disk every machine is cloned from. Empty means whatever
	// ferry-machined was started with, which is the ordinary case: the image is
	// a property of the installation rather than of a workload.
	Image string `json:"image,omitempty"`

	// CPUs bounds the cores a machine may have.
	CPUs Range `json:"cpus,omitempty"`
	// Memory bounds the memory ceiling a machine may have, in GiB.
	MemoryGi Range `json:"memoryGi,omitempty"`

	// Limits is what this Mac will commit to machines in total. Reaching it is
	// not an error: it is the point at which Karpenter is told there is no
	// capacity, the same answer a cloud gives when a zone is full.
	Limits Limits `json:"limits,omitempty"`

	// MaxPods a machine advertises. A node VM shares one kernel between its
	// pods, so this is Kubernetes' own default rather than ferry mode 1's
	// memory-derived number.
	MaxPods int64 `json:"maxPods,omitempty"`
}

type Range struct {
	Min int64 `json:"min,omitempty"`
	Max int64 `json:"max,omitempty"`
}

type Limits struct {
	CPUs     int64 `json:"cpus,omitempty"`
	MemoryGi int64 `json:"memoryGi,omitempty"`
}

type FerryNodeClassStatus struct {
	Conditions []status.Condition `json:"conditions,omitempty"`
}

// Defaults that make a NodeClass with an empty spec still provision something
// reasonable on a laptop, rather than nothing.
func (n *FerryNodeClass) bounds() bounds {
	b := bounds{
		minCPUs:     orDefault(n.Spec.CPUs.Min, 2),
		maxCPUs:     orDefault(n.Spec.CPUs.Max, 8),
		minMemoryGi: orDefault(n.Spec.MemoryGi.Min, 2),
		maxMemoryGi: orDefault(n.Spec.MemoryGi.Max, 16),
		// Zero means unbounded, and that is deliberately not the default: a
		// provisioner with no ceiling on a laptop will find the ceiling by
		// hitting it.
		limitCPUs:     orDefault(n.Spec.Limits.CPUs, 8),
		limitMemoryGi: orDefault(n.Spec.Limits.MemoryGi, 16),
	}
	return b
}

func (n *FerryNodeClass) maxPods() int64 { return orDefault(n.Spec.MaxPods, 110) }

func orDefault(v, d int64) int64 {
	if v == 0 {
		return d
	}
	return v
}

// --- status.Object -------------------------------------------------------

func (n *FerryNodeClass) GetConditions() []status.Condition { return n.Status.Conditions }

func (n *FerryNodeClass) SetConditions(c []status.Condition) { n.Status.Conditions = c }

func (n *FerryNodeClass) StatusConditions(opts ...status.ForOption) status.ConditionSet {
	return status.NewReadyConditions().For(n, opts...)
}

// --- runtime.Object ------------------------------------------------------

// DeepCopy has to be declared on this type rather than inherited. Without it
// `nc.DeepCopy()` resolves to the embedded ObjectMeta's method and returns an
// *ObjectMeta, which compiles everywhere it is assigned to an interface and
// fails only where a client.Object is wanted -- and would silently copy none of
// the spec if it did not.
func (n *FerryNodeClass) DeepCopy() *FerryNodeClass {
	if n == nil {
		return nil
	}
	out := new(FerryNodeClass)
	*out = *n
	out.TypeMeta = n.TypeMeta
	n.ObjectMeta.DeepCopyInto(&out.ObjectMeta)
	if n.Status.Conditions != nil {
		out.Status.Conditions = make([]status.Condition, len(n.Status.Conditions))
		copy(out.Status.Conditions, n.Status.Conditions)
	}
	return out
}

func (n *FerryNodeClass) DeepCopyObject() runtime.Object {
	if n == nil {
		return nil
	}
	return n.DeepCopy()
}

// +kubebuilder:object:root=true
type FerryNodeClassList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []FerryNodeClass `json:"items"`
}

func (l *FerryNodeClassList) DeepCopyObject() runtime.Object {
	if l == nil {
		return nil
	}
	out := new(FerryNodeClassList)
	out.TypeMeta = l.TypeMeta
	l.ListMeta.DeepCopyInto(&out.ListMeta)
	if l.Items != nil {
		out.Items = make([]FerryNodeClass, len(l.Items))
		for i := range l.Items {
			// Deep, not the shallow struct assignment this used to be. The type
			// is in client-go's scheme, so controller-runtime's cache calls
			// this before handing a list to a reconciler; sharing the labels
			// map and the conditions slice with the cached object means a
			// reconciler editing what it believes is its own copy edits the
			// informer's.
			out.Items[i] = *l.Items[i].DeepCopy()
		}
	}
	return out
}
