// SPDX-FileCopyrightText: The RamenDR authors
// SPDX-License-Identifier: Apache-2.0

package controllers

import (
	"context"

	volrep "github.com/csi-addons/kubernetes-csi-addons/api/replication.storage/v1alpha1"
	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	corev1 "k8s.io/api/core/v1"
	storagev1 "k8s.io/api/storage/v1"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"

	ramendrv1alpha1 "github.com/ramendr/ramen/api/v1alpha1"
	rmnutil "github.com/ramendr/ramen/internal/controller/util"
)

const (
	resyncAnnotationTestNamespace   = "vrg-ns"
	resyncAnnotationTestPVC         = "pvc-a"
	resyncAnnotationTestSC          = "sc"
	resyncAnnotationTestProvisioner = "test.csi.example.com"
	resyncAnnotationTestSchedule    = "5m"
)

var resyncAnnotationTestVRName = types.NamespacedName{
	Name:      resyncAnnotationTestPVC,
	Namespace: resyncAnnotationTestNamespace,
}

// resyncAnnotationTestVRGInstance builds a primary VRGInstance, backed by a fake client holding objs, with a
// single VolRep protected PVC and a matching VolumeReplicationClass. When resyncOnPrimary is set the VRG has
// the resync-on-primary annotation.
func resyncAnnotationTestVRGInstance(resyncOnPrimary bool, objs ...runtime.Object) *VRGInstance {
	scheme := runtime.NewScheme()
	Expect(corev1.AddToScheme(scheme)).To(Succeed())
	Expect(volrep.AddToScheme(scheme)).To(Succeed())
	Expect(ramendrv1alpha1.AddToScheme(scheme)).To(Succeed())

	scName := resyncAnnotationTestSC

	vrg := &ramendrv1alpha1.VolumeReplicationGroup{
		ObjectMeta: metav1.ObjectMeta{Name: "vrg", Namespace: resyncAnnotationTestNamespace, UID: "vrg-uid"},
		Spec: ramendrv1alpha1.VolumeReplicationGroupSpec{
			ReplicationState: ramendrv1alpha1.Primary,
			Async:            &ramendrv1alpha1.VRGAsyncSpec{SchedulingInterval: resyncAnnotationTestSchedule},
		},
	}

	if resyncOnPrimary {
		vrg.SetAnnotations(map[string]string{rmnutil.ResyncOnPrimaryAnnotation: "true"})
	}

	return &VRGInstance{
		reconciler: &VolumeReplicationGroupReconciler{
			Client: fake.NewClientBuilder().WithScheme(scheme).WithRuntimeObjects(objs...).Build(),
			Scheme: scheme,
		},
		ctx:         context.TODO(),
		log:         logr.Discard(),
		instance:    vrg,
		ramenConfig: &ramendrv1alpha1.RamenConfig{},
		volRepPVCs: []corev1.PersistentVolumeClaim{{
			ObjectMeta: metav1.ObjectMeta{Name: resyncAnnotationTestPVC, Namespace: resyncAnnotationTestNamespace},
			Spec:       corev1.PersistentVolumeClaimSpec{StorageClassName: &scName},
		}},
		storageClassCache: map[string]*storagev1.StorageClass{
			resyncAnnotationTestSC: {
				ObjectMeta:  metav1.ObjectMeta{Name: resyncAnnotationTestSC},
				Provisioner: resyncAnnotationTestProvisioner,
			},
		},
		replClassList: &volrep.VolumeReplicationClassList{Items: []volrep.VolumeReplicationClass{{
			ObjectMeta: metav1.ObjectMeta{Name: "vrc"},
			Spec: volrep.VolumeReplicationClassSpec{
				Provisioner: resyncAnnotationTestProvisioner,
				Parameters:  map[string]string{ReplicationClassScheduleKey: resyncAnnotationTestSchedule},
			},
		}}},
		grpReplClassList: &volrep.VolumeGroupReplicationClassList{},
		vrcUpdated:       true,
	}
}

// resyncAnnotationTestVR builds a VR for the test PVC in state, reporting it was promoted for its current
// generation. When resyncOnPrimary is set the VR has the VR resync-on-primary annotation.
func resyncAnnotationTestVR(state volrep.ReplicationState, resyncOnPrimary bool) *volrep.VolumeReplication {
	const generation = 1

	vr := &volrep.VolumeReplication{
		ObjectMeta: metav1.ObjectMeta{
			Name:        resyncAnnotationTestVRName.Name,
			Namespace:   resyncAnnotationTestVRName.Namespace,
			Generation:  generation,
			Annotations: map[string]string{"other": "kept"},
		},
		Spec: volrep.VolumeReplicationSpec{
			ReplicationState:       state,
			VolumeReplicationClass: "vrc",
		},
		Status: volrep.VolumeReplicationStatus{
			ObservedGeneration: generation,
			Conditions: []metav1.Condition{
				{
					Type: volrep.ConditionValidated, Status: metav1.ConditionTrue,
					ObservedGeneration: generation, Reason: "Validated",
				},
				{
					Type: volrep.ConditionCompleted, Status: metav1.ConditionTrue,
					ObservedGeneration: generation, Reason: "Promoted",
				},
			},
		},
	}

	if resyncOnPrimary {
		vr.Annotations[vrResyncOnPrimaryAnnotation] = "true"
	}

	return vr
}

func getResyncAnnotationTestVR(v *VRGInstance) *volrep.VolumeReplication {
	GinkgoHelper()

	vr := &volrep.VolumeReplication{}
	Expect(v.reconciler.Get(context.TODO(), resyncAnnotationTestVRName, vr)).To(Succeed())

	return vr
}

func expectVRResyncOnPrimaryAnnotation(vr *volrep.VolumeReplication, present bool) {
	GinkgoHelper()

	if present {
		Expect(vr.GetAnnotations()).To(HaveKeyWithValue(vrResyncOnPrimaryAnnotation, "true"))
	} else {
		Expect(vr.GetAnnotations()).NotTo(HaveKey(vrResyncOnPrimaryAnnotation))
	}

	// The VRG annotation key is not set on the VR.
	Expect(vr.GetAnnotations()).NotTo(HaveKey(rmnutil.ResyncOnPrimaryAnnotation))
}

func pvcDataReadyCondition(v *VRGInstance) *metav1.Condition {
	GinkgoHelper()

	protectedPVC := v.findProtectedPVC(resyncAnnotationTestNamespace, resyncAnnotationTestPVC)
	Expect(protectedPVC).NotTo(BeNil())

	return meta.FindStatusCondition(protectedPVC.Conditions, VRGConditionTypeDataReady)
}

var _ = Describe("VRG resync-on-primary annotation propagation to VR", func() {
	DescribeTable("syncVRResyncOnPrimaryAnnotation",
		func(vrgAnnotations, vrAnnotations map[string]string, wantChanged bool, wantVRAnnotations map[string]string) {
			v := resyncAnnotationTestVRGInstance(false)
			v.instance.SetAnnotations(vrgAnnotations)

			vr := &volrep.VolumeReplication{ObjectMeta: metav1.ObjectMeta{Annotations: vrAnnotations}}

			Expect(v.syncVRResyncOnPrimaryAnnotation(vr)).To(Equal(wantChanged))
			Expect(vr.GetAnnotations()).To(Equal(wantVRAnnotations))
		},
		Entry("absent on VRG and VR", nil, nil, false, nil),
		Entry("absent on VRG, other VR annotations kept",
			nil, map[string]string{"other": "kept"},
			false, map[string]string{"other": "kept"}),
		Entry("added to VR with no annotations",
			map[string]string{rmnutil.ResyncOnPrimaryAnnotation: "true"}, nil,
			true, map[string]string{vrResyncOnPrimaryAnnotation: "true"}),
		Entry("value copied as-is",
			map[string]string{rmnutil.ResyncOnPrimaryAnnotation: ""}, map[string]string{"other": "kept"},
			true, map[string]string{"other": "kept", vrResyncOnPrimaryAnnotation: ""}),
		Entry("value updated",
			map[string]string{rmnutil.ResyncOnPrimaryAnnotation: "false"},
			map[string]string{vrResyncOnPrimaryAnnotation: "true"},
			true, map[string]string{vrResyncOnPrimaryAnnotation: "false"}),
		Entry("already in sync",
			map[string]string{rmnutil.ResyncOnPrimaryAnnotation: "true"},
			map[string]string{vrResyncOnPrimaryAnnotation: "true"},
			false, map[string]string{vrResyncOnPrimaryAnnotation: "true"}),
		Entry("removed from VR when absent on VRG",
			nil, map[string]string{"other": "kept", vrResyncOnPrimaryAnnotation: "true"},
			true, map[string]string{"other": "kept"}),
	)

	DescribeTable("createVR",
		func(resyncOnPrimary bool) {
			v := resyncAnnotationTestVRGInstance(resyncOnPrimary)

			Expect(v.createVR(resyncAnnotationTestVRName, volrep.Primary)).To(Succeed())

			expectVRResyncOnPrimaryAnnotation(getResyncAnnotationTestVR(v), resyncOnPrimary)
		},
		Entry("sets the VR annotation when the VRG has the annotation", true),
		Entry("does not set the VR annotation when the VRG does not have the annotation", false),
	)

	DescribeTable("updateVR when the VR state already matches",
		func(vrgResyncOnPrimary, vrResyncOnPrimary bool) {
			v := resyncAnnotationTestVRGInstance(vrgResyncOnPrimary,
				resyncAnnotationTestVR(volrep.Primary, vrResyncOnPrimary))
			vr := getResyncAnnotationTestVR(v)

			requeue, ready, err := v.updateVR(&v.volRepPVCs[0], vr, volrep.Primary, v.log)
			Expect(err).NotTo(HaveOccurred())
			Expect(requeue).To(BeFalse())

			// The status check runs, rather than the PVC being marked progressing.
			Expect(ready).To(BeTrue())
			Expect(pvcDataReadyCondition(v).Reason).To(Equal(VRGConditionReasonReady))

			got := getResyncAnnotationTestVR(v)
			expectVRResyncOnPrimaryAnnotation(got, vrgResyncOnPrimary)
			Expect(got.GetAnnotations()).To(HaveKeyWithValue("other", "kept"))
			Expect(got.Spec.ReplicationState).To(Equal(volrep.Primary))
		},
		Entry("adds the VR annotation when added to the VRG", true, false),
		Entry("removes the VR annotation when removed from the VRG", false, true),
		Entry("keeps the VR annotation when present on the VRG", true, true),
		Entry("does not add the VR annotation when absent from the VRG", false, false),
	)

	It("updateVR updates both the VR annotation and state", func() {
		v := resyncAnnotationTestVRGInstance(true, resyncAnnotationTestVR(volrep.Secondary, false))
		vr := getResyncAnnotationTestVR(v)

		requeue, ready, err := v.updateVR(&v.volRepPVCs[0], vr, volrep.Primary, v.log)
		Expect(err).NotTo(HaveOccurred())
		Expect(requeue).To(BeFalse())
		Expect(ready).To(BeFalse())
		Expect(pvcDataReadyCondition(v).Reason).To(Equal(VRGConditionReasonProgressing))

		got := getResyncAnnotationTestVR(v)
		expectVRResyncOnPrimaryAnnotation(got, true)
		Expect(got.Spec.ReplicationState).To(Equal(volrep.Primary))
	})
})
