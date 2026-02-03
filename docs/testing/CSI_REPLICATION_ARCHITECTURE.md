# CSI Replication: What Gets Replicated and Where

## Summary

**PVC and PV are NOT replicated to DR2 during normal operation.** Only the underlying RBD image data is replicated via Ceph mirroring.

## Architecture

### During Normal Replication (DR1 as Primary)

```
┌─────────────────────────────────────────────────────────────────┐
│ DR1 (Primary Cluster)                                           │
├─────────────────────────────────────────────────────────────────┤
│ ✅ Kubernetes Objects:                                          │
│    • PVC (test-replication-pvc)                                 │
│    • PV (pvc-xxxx)                                              │
│    • VolumeReplication (state: Primary)                         │
│                                                                 │
│ ✅ Storage Layer:                                               │
│    • RBD image (csi-vol-xxxx) - READ/WRITE                      │
│    • Ceph RBD mirroring agent - sending snapshots →            │
└─────────────────────────────────────────────────────────────────┘
                                 │
                                 │ Snapshot Replication
                                 │ (via RBD mirroring)
                                 ↓
┌─────────────────────────────────────────────────────────────────┐
│ DR2 (Secondary Cluster)                                         │
├─────────────────────────────────────────────────────────────────┤
│ ❌ Kubernetes Objects:                                          │
│    • NO PVC                                                     │
│    • NO PV                                                      │
│    • NO VolumeReplication                                       │
│                                                                 │
│ ✅ Storage Layer:                                               │
│    • RBD image (csi-vol-xxxx) - READ-ONLY replica               │
│    • Ceph RBD mirroring agent - receiving snapshots ←          │
└─────────────────────────────────────────────────────────────────┘
```

## CSI Replication Components & Architecture

### CSI-Replication Entities and Responsibilities

#### 1. VolumeReplication Custom Resource
**Purpose:** Kubernetes API abstraction for volume replication operations

```yaml
apiVersion: replication.storage.openshift.io/v1alpha1
kind: VolumeReplication
metadata:
  name: test-volume-replication
spec:
  volumeReplicationClass: rook-ceph-block-volumereplicationclass
  pvcName: test-replication-pvc
  replicationState: primary  # primary | secondary
```

**Responsibilities:**
- Define replication policy and state (primary/secondary)
- Track replication status and health
- Trigger promotion/demotion operations
- Provide status feedback to higher-level orchestrators (Ramen)

#### 2. VolumeReplicationClass
**Purpose:** Define replication parameters and provisioner configuration

```yaml
apiVersion: replication.storage.openshift.io/v1alpha1
kind: VolumeReplicationClass
metadata:
  name: rook-ceph-block-volumereplicationclass
spec:
  provisioner: rook-ceph.rbd.csi.ceph.com
  parameters:
    mirroringMode: snapshot  # snapshot | journal
    schedulingInterval: "1m"
    replication.storage.openshift.io/replication-secret-name: rook-csi-rbd-provisioner
    replication.storage.openshift.io/replication-secret-namespace: rook-ceph
```

**Responsibilities:**
- Configure replication mode (snapshot vs journal)
- Set scheduling intervals for replication
- Reference authentication secrets
- Define CSI driver parameters

#### 3. CSI Replication Driver (csi-addons)
**Purpose:** Implements CSI replication specification

**Components:**
- **Controller Service:** Handles CreateVolumeReplication, DeleteVolumeReplication calls
- **Node Service:** Manages replication at node level (if needed)
- **Identity Service:** Provides driver capabilities and health

### Detailed Component Interaction Flow

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│ Kubernetes API Layer                                                             │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│  VolumeReplication CR ──────┐    VolumeReplicationClass                         │
│  └── pvcName: test-pvc      │    └── provisioner: rook-ceph.rbd.csi.ceph.com   │
│  └── state: primary         │    └── mirroringMode: snapshot                    │
│                              │                                                  │
└──────────────────────────────┼──────────────────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│ CSI-Addons Controller Layer                                                      │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│  ┌─────────────────────┐    │    ┌─────────────────────────────────────────┐   │
│  │ csi-addons-controller│◄──┼───►│ Replication Sidecar                    │   │
│  │                     │    │    │ - Watches VolumeReplication CRs        │   │
│  │ - Manages lifecycle │    │    │ - Calls CSI ReplicationController RPCs │   │
│  │ - Updates status    │    │    │ - Handles promotion/demotion           │   │
│  │ - Handles events    │    │    │ - Monitors replication health          │   │
│  └─────────────────────┘    │    └─────────────────────────────────────────┘   │
│                              │                                                  │
└──────────────────────────────┼──────────────────────────────────────────────────┘
                               │
                               │ gRPC CSI Calls:
                               │ • EnableVolumeReplication()
                               │ • DisableVolumeReplication() 
                               │ • PromoteVolume()
                               │ • DemoteVolume()
                               │ • ResyncVolume()
                               │ • GetVolumeReplicationInfo()
                               ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│ CSI Driver Layer (Rook-Ceph)                                                     │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│  ┌─────────────────────────────────────────────────────────────────────────┐   │
│  │ Rook-Ceph CSI Driver (csi-rbdplugin)                                   │   │
│  │                                                                         │   │
│  │ ReplicationController Service:                                          │   │
│  │ ├── EnableVolumeReplication(volumeID, parameters)                      │   │
│  │ ├── DisableVolumeReplication(volumeID)                                 │   │
│  │ ├── PromoteVolume(volumeID, force=false)                               │   │
│  │ ├── DemoteVolume(volumeID)                                             │   │
│  │ └── GetVolumeReplicationInfo(volumeID)                                 │   │
│  │                                                                         │   │
│  │ Implementation:                                                         │   │
│  │ └── Translates CSI calls to RBD mirroring commands                     │   │
│  └─────────────────────────────────────────────────────────────────────────┘   │
│                              │                                                  │
└──────────────────────────────┼──────────────────────────────────────────────────┘
                               │
                               │ RBD Commands:
                               │ • rbd mirror pool enable
                               │ • rbd mirror image enable  
                               │ • rbd mirror image promote
                               │ • rbd mirror image demote
                               │ • rbd mirror image status
                               ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│ Ceph Storage Layer                                                              │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│  ┌─────────────────────┐    ┌─────────────────────┐    ┌─────────────────────┐  │
│  │ RBD Image           │    │ RBD Mirroring       │    │ Journal/Snapshot    │  │
│  │ csi-vol-xxxxx      │    │ Daemon              │    │ Mechanism           │  │
│  │                     │    │                     │    │                     │  │
│  │ - Block device      │◄──►│ - Monitors images   │◄──►│ - Tracks changes    │  │
│  │ - Primary/secondary │    │ - Handles sync      │    │ - Creates snapshots │  │
│  │ - Access mode       │    │ - Manages failover  │    │ - Replays journal   │  │
│  │ - Metadata          │    │ - Status reporting  │    │ - Conflict resolution│  │
│  └─────────────────────┘    └─────────────────────┘    └─────────────────────┘  │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

## Ceph-Rook Entities and Tools

### Rook-Ceph Components

#### 1. Rook Operator
**Purpose:** Manages Ceph cluster lifecycle and CSI driver deployment

**Responsibilities:**
- Deploys and configures Ceph components
- Manages CSI driver pods (csi-rbdplugin)
- Handles storage class creation
- Monitors cluster health

#### 2. Ceph Monitor (MON)
**Purpose:** Maintains cluster state and configuration

```bash
# Check monitor status
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph mon stat
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status
```

#### 3. Ceph Object Storage Daemon (OSD)
**Purpose:** Stores actual data blocks

```bash
# List OSDs
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph osd ls
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph osd tree
```

#### 4. Ceph Manager (MGR)
**Purpose:** Provides management and monitoring interfaces

### RBD Mirroring Architecture

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│ Site 1 (DR1) - Primary Site                                                      │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│  ┌─────────────────┐   ┌─────────────────┐   ┌─────────────────────────────┐    │
│  │ Ceph Cluster 1  │   │ RBD Pool        │   │ RBD Mirroring Daemon        │    │
│  │                 │   │ (replicapool)   │   │ (rbd-mirror)                │    │
│  │ MONs: 3         │   │                 │   │                             │    │
│  │ OSDs: 6         │   │ Images:         │   │ - Discovers mirror-enabled  │    │
│  │ MGRs: 2         │   │ ├─ csi-vol-xxx │   │   images                    │    │
│  │                 │   │ ├─ csi-vol-yyy │   │ - Creates snapshots/journal │    │
│  │ Pool Config:    │   │ └─ csi-vol-zzz │   │ - Transfers to remote       │    │
│  │ - Size: 3       │   │                 │   │ - Handles failover scenarios│    │
│  │ - Min Size: 2   │   │ Mirror Mode:    │   │ - Reports status            │    │
│  └─────────────────┘   │ - snapshot      │   └─────────────────────────────┘    │
│                        │ - pool-level    │                                      │
│                        └─────────────────┘                                      │
└─────────────────────────────────────────┼───────────────────────────────────────┘
                                          │
                                          │ Network Replication
                                          │ (Port 6789, 6800-7100)
                                          │
                                          │ Modes:
                                          │ ┌─ Snapshot: Periodic snapshots
                                          │ │  - Lower overhead
                                          │ │  - Higher RPO (1-5min)
                                          │ │  - Async replication
                                          │ │
                                          │ └─ Journal: Write ordering
                                          │    - Near-sync replication  
                                          │    - Lower RPO (<30s)
                                          │    - Higher overhead
                                          │
                                          ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│ Site 2 (DR2) - Secondary Site                                                    │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│  ┌─────────────────┐   ┌─────────────────┐   ┌─────────────────────────────┐    │
│  │ Ceph Cluster 2  │   │ RBD Pool        │   │ RBD Mirroring Daemon        │    │
│  │                 │   │ (replicapool)   │   │ (rbd-mirror)                │    │
│  │ MONs: 3         │   │                 │   │                             │    │
│  │ OSDs: 6         │   │ Replica Images: │   │ - Receives snapshots/journal│    │
│  │ MGRs: 2         │   │ ├─ csi-vol-xxx │   │ - Applies changes locally   │    │
│  │                 │   │ ├─ csi-vol-yyy │   │ - Maintains sync state      │    │
│  │ Pool Config:    │   │ └─ csi-vol-zzz │   │ - Ready for promotion       │    │
│  │ - Size: 3       │   │ (read-only)     │   │ - Health monitoring         │    │
│  │ - Min Size: 2   │   │                 │   └─────────────────────────────┘    │
│  └─────────────────┘   │ Mirror Status:  │                                      │
│                        │ - up+replaying  │                                      │
│                        └─────────────────┘                                      │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### Key RBD Tools and Commands

#### Pool and Image Management
```bash
# List pools
rbd pool ls

# Create pool with mirroring
ceph osd pool create replicapool 32 32
rbd pool init replicapool

# Enable pool-level mirroring
rbd mirror pool enable replicapool snapshot
rbd mirror pool peer bootstrap create replicapool > /tmp/bootstrap_token
```

#### Mirroring Configuration
```bash
# Add peer (on secondary site)
rbd mirror pool peer bootstrap import replicapool /tmp/bootstrap_token

# Enable image-level mirroring
rbd mirror image enable replicapool/csi-vol-xxxxx snapshot

# Check mirror status
rbd mirror image status replicapool/csi-vol-xxxxx
```

#### Status and Health Commands
```bash
# Overall mirror status
rbd mirror pool status replicapool --verbose

# Image details
rbd mirror image status replicapool/csi-vol-xxxxx --verbose

# Daemon status
rbd mirror service status

# Check replication lag
rbd mirror pool status replicapool --format json | jq '.images[] | {name, description, last_update}'
```

## Replication Modes: Journal vs Snapshot

### Snapshot-based Replication (Default)

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│ Snapshot-based Replication Flow                                                  │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│ Primary Site (DR1)                        Secondary Site (DR2)                  │
│                                                                                 │
│ ┌─────────────────────┐                  ┌─────────────────────────────────┐   │
│ │ RBD Image           │                  │ RBD Image (replica)             │   │
│ │ csi-vol-xxxxx       │                  │ csi-vol-xxxxx                   │   │
│ │                     │                  │                                 │   │
│ │ Write Operations    │                  │ [Read-Only]                     │   │
│ │ ┌─────────────────┐ │                  │ ┌─────────────────────────────┐ │   │
│ │ │ User App writes │ │                  │ │ Awaiting snapshots          │ │   │
│ │ │ Block 1: Data A │ │                  │ │                             │ │   │
│ │ │ Block 2: Data B │ │                  │ │                             │ │   │
│ │ │ Block 3: Data C │ │                  │ │                             │ │   │
│ │ └─────────────────┘ │                  │ └─────────────────────────────┘ │   │
│ │         │           │                  │                                 │   │
│ │         ▼           │                  │                                 │   │
│ │ ┌─────────────────┐ │    Snapshot      │ ┌─────────────────────────────┐ │   │
│ │ │ Snapshot Timer  │ │◄────Transfer────►│ │ Snapshot Application        │ │   │
│ │ │ (every 1min)    │ │                  │ │                             │ │   │
│ │ │                 │ │                  │ │ T=0:   [Empty]              │ │   │
│ │ │ T=1: snap-001   │ │─────────────────►│ │ T=1:   snap-001 → Applied   │ │   │
│ │ │ T=2: snap-002   │ │─────────────────►│ │ T=2:   snap-002 → Applied   │ │   │
│ │ │ T=3: snap-003   │ │─────────────────►│ │ T=3:   snap-003 → Applied   │ │   │
│ │ └─────────────────┘ │                  │ └─────────────────────────────┘ │   │
│ │                     │                  │                                 │   │
│ │ Status: up+stopped  │                  │ Status: up+replaying            │   │
│ └─────────────────────┘                  └─────────────────────────────────┘   │
│                                                                                 │
│ Characteristics:                                                                │
│ • RPO: 1-5 minutes (configurable)                                              │
│ • Overhead: Low                                                                 │
│ • Network: Periodic bursts                                                      │
│ • Consistency: Point-in-time consistent                                         │
│ • Use case: Standard DR scenarios                                              │
└─────────────────────────────────────────────────────────────────────────────────┘
```

**Configuration:**
```yaml
parameters:
  mirroringMode: "snapshot"
  schedulingInterval: "1m"  # Can be 30s, 1m, 5m, etc.
```

### Journal-based Replication (Near-Synchronous)

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│ Journal-based Replication Flow                                                   │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│ Primary Site (DR1)                        Secondary Site (DR2)                  │
│                                                                                 │
│ ┌─────────────────────┐                  ┌─────────────────────────────────┐   │
│ │ RBD Image           │                  │ RBD Image (replica)             │   │
│ │ csi-vol-xxxxx       │                  │ csi-vol-xxxxx                   │   │
│ │                     │                  │                                 │   │
│ │ ┌─────────────────┐ │                  │ ┌─────────────────────────────┐ │   │
│ │ │ User App        │ │                  │ │ Journal Replay              │ │   │
│ │ │                 │ │                  │ │                             │ │   │
│ │ │ Write Block 1   │ │                  │ │ Waiting for entries         │ │   │
│ │ │      ┌─────────┐│ │                  │ │                             │ │   │
│ │ │      │ Write   ││ │    Journal       │ │ ┌─────────────────────────┐ │ │   │
│ │ │      │ Buffer  ││ │◄────Entries─────►│ │ │ Journal Buffer          │ │ │   │
│ │ │      └─────────┘│ │                  │ │ │                         │ │ │   │
│ │ │           │     │ │                  │ │ │ Entry 1: Write Block 1  │ │ │   │
│ │ │           ▼     │ │                  │ │ │ Entry 2: Write Block 2  │ │ │   │
│ │ │ ┌─────────────┐ │ │                  │ │ │ Entry 3: Write Block 3  │ │ │   │
│ │ │ │ Journal Log │ │ │                  │ │ └─────────────────────────┘ │ │   │
│ │ │ │ Entry 1     │ │ │─────────────────►│ │            │                │ │   │
│ │ │ │ Entry 2     │ │ │─────────────────►│ │            ▼                │ │   │
│ │ │ │ Entry 3     │ │ │─────────────────►│ │ ┌─────────────────────────┐ │ │   │
│ │ │ └─────────────┘ │ │                  │ │ │ Apply to RBD Image      │ │ │   │
│ │ │           │     │ │                  │ │ │ Block 1 ← Entry 1      │ │ │   │
│ │ │           ▼     │ │                  │ │ │ Block 2 ← Entry 2      │ │ │   │
│ │ │ ┌─────────────┐ │ │                  │ │ │ Block 3 ← Entry 3      │ │ │   │
│ │ │ │ RBD Blocks  │ │ │                  │ │ └─────────────────────────┘ │ │   │
│ │ │ │ [Committed] │ │ │                  │ │                             │ │   │
│ │ │ └─────────────┘ │ │                  │ │                             │ │   │
│ │ └─────────────────┘ │                  │ └─────────────────────────────┘ │   │
│ │                     │                  │                                 │   │
│ │ Status: up+stopped  │                  │ Status: up+replaying            │   │
│ └─────────────────────┘                  └─────────────────────────────────┘   │
│                                                                                 │
│ Characteristics:                                                                │
│ • RPO: < 30 seconds (near real-time)                                           │
│ • Overhead: Higher (continuous streaming)                                       │
│ • Network: Constant, low-latency required                                       │
│ • Consistency: Write-order preserved                                            │
│ • Use case: Mission-critical, low-RPO scenarios                                │
└─────────────────────────────────────────────────────────────────────────────────┘
```

**Configuration:**
```yaml
parameters:
  mirroringMode: "journal"
  # No scheduling interval - continuous replication
```

### Mode Comparison Table

| Feature | Snapshot Mode | Journal Mode |
|---------|---------------|--------------|
| **RPO** | 1-5 minutes | < 30 seconds |
| **Network Overhead** | Low (periodic) | Higher (continuous) |
| **Storage Overhead** | Medium (snapshots) | Higher (journal + data) |
| **Consistency** | Point-in-time | Write-order preserved |
| **Failover Speed** | Fast | Fastest |
| **Network Requirements** | Standard | Low-latency preferred |
| **Use Case** | Standard DR | Mission-critical DR |
| **Resource Usage** | Lower | Higher |

### Replication API Implementation

The CSI replication API translates Kubernetes operations into Ceph RBD commands:

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│ CSI Replication API to RBD Command Translation                                   │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│ CSI API Call                     RBD Command(s)                                 │
│ ════════════                     ═══════════════                                 │
│                                                                                 │
│ EnableVolumeReplication()   ──►  rbd mirror image enable                        │
│                                  replicapool/csi-vol-xxxxx snapshot             │
│                                                                                 │
│ DisableVolumeReplication()  ──►  rbd mirror image disable                       │
│                                  replicapool/csi-vol-xxxxx                      │
│                                                                                 │
│ PromoteVolume()            ──►  rbd mirror image promote                        │
│                                  replicapool/csi-vol-xxxxx --force              │
│                                                                                 │
│ DemoteVolume()             ──►  rbd mirror image demote                         │
│                                  replicapool/csi-vol-xxxxx                      │
│                                                                                 │
│ ResyncVolume()             ──►  rbd mirror image resync                         │
│                                  replicapool/csi-vol-xxxxx                      │
│                                                                                 │
│ GetVolumeReplicationInfo() ──►  rbd mirror image status                         │
│                                  replicapool/csi-vol-xxxxx --format json        │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

## CSI-Addons Controller to Replication Sidecar Connection

### Connection Architecture

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│ CSI-Addons Controller Communication Flow                                         │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│ ┌─────────────────────────┐                                                     │
│ │ csi-addons-controller   │                                                     │
│ │ (Deployment)            │                                                     │
│ │                         │                                                     │
│ │ VolumeReplication       │     1. Watch VR CRs                                 │
│ │ Controller:             │◄──────────────────────────                         │
│ │ ├─ Watch VR CRs        │                                                     │
│ │ ├─ Validate specs      │                                                     │
│ │ ├─ Update status       │                                                     │
│ │ └─ Handle events       │                                                     │
│ │                         │                                                     │
│ │ gRPC Client:           │     2. Discover CSI Endpoints                       │
│ │ ├─ Service Discovery   │◄──────────────────────────                         │
│ │ ├─ Connection Pool     │                                                     │
│ │ └─ Request Routing     │                                                     │
│ └─────────────────────────┘                                                     │
│              │                                                                  │
│              │ 3. gRPC Call                                                     │
│              │ (ReplicationController Service)                                  │
│              │                                                                  │
│              ▼                                                                  │
│ ┌─────────────────────────┐                                                     │
│ │ CSI Driver Pod          │                                                     │
│ │ (DaemonSet)             │                                                     │
│ │                         │                                                     │
│ │ ┌─────────────────────┐ │                                                     │
│ │ │ csi-rbdplugin       │ │                                                     │
│ │ │                     │ │                                                     │
│ │ │ Standard CSI:       │ │                                                     │
│ │ │ ├─ Identity        │ │                                                     │
│ │ │ ├─ Controller      │ │                                                     │
│ │ │ └─ Node            │ │                                                     │
│ │ │                     │ │                                                     │
│ │ │ CSI-Addons:         │ │     4. Process Replication Request                  │
│ │ │ └─ Replication ◄────┼─┼──────────────────────────                         │
│ │ │    Controller       │ │                                                     │
│ │ └─────────────────────┘ │                                                     │
│ │                         │                                                     │
│ │ ┌─────────────────────┐ │                                                     │
│ │ │ replication-sidecar │ │                                                     │
│ │ │                     │ │                                                     │
│ │ │ ├─ gRPC Server      │ │     5. Sidecar Handles Request                     │
│ │ │ ├─ Unix Socket      │ │◄──────────────────────────                         │
│ │ │ ├─ Identity Service │ │                                                     │
│ │ │ └─ Replication APIs │ │                                                     │
│ │ └─────────────────────┘ │                                                     │
│ └─────────────────────────┘                                                     │
│              │                                                                  │
│              │ 6. Execute RBD Commands                                          │
│              │                                                                  │
│              ▼                                                                  │
│ ┌─────────────────────────────────────────────────────────────────────────┐   │
│ │ Ceph Cluster                                                            │   │
│ │                                                                         │   │
│ │ rbd mirror image enable replicapool/csi-vol-xxxxx snapshot             │   │
│ │ rbd mirror image promote replicapool/csi-vol-xxxxx                     │   │
│ │ rbd mirror image status replicapool/csi-vol-xxxxx                      │   │
│ └─────────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### Service Discovery Mechanism

#### 1. CSI Driver Registration
The CSI driver registers with kubelet through the standard CSI registration process:

```bash
# CSI driver socket location
/var/lib/kubelet/plugins/rook-ceph.rbd.csi.ceph.com/csi.sock

# CSI-addons socket (additional)
/var/lib/kubelet/plugins/rook-ceph.rbd.csi.ceph.com/csi-addons.sock
```

#### 2. CSI-Addons Discovery
The controller discovers CSI-addons endpoints through:

```yaml
# CSIAddonsNode CRD - automatically created
apiVersion: csiaddons.openshift.io/v1alpha1
kind: CSIAddonsNode
metadata:
  name: rook-ceph-block-csi-driver-node-xxxxx
spec:
  driver:
    name: rook-ceph.rbd.csi.ceph.com
    endpoint: unix:///var/lib/kubelet/plugins/rook-ceph.rbd.csi.ceph.com/csi-addons.sock
  nodeID: node-01
```

#### 3. Connection Establishment

```go
// Simplified connection logic in csi-addons-controller
func (r *VolumeReplicationReconciler) getCSIConnection(driverName string) (*grpc.ClientConn, error) {
    // 1. Find CSIAddonsNode for this driver
    csiAddonsNode, err := r.findCSIAddonsNode(driverName)
    if err != nil {
        return nil, err
    }
    
    // 2. Extract endpoint
    endpoint := csiAddonsNode.Spec.Driver.Endpoint
    
    // 3. Establish gRPC connection
    conn, err := grpc.Dial(endpoint,
        grpc.WithTransportCredentials(insecure.NewCredentials()),
        grpc.WithTimeout(30*time.Second))
        
    return conn, err
}
```

### Error Handling and Retry Logic

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│ Error Handling Flow                                                              │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│ VolumeReplication Status Updates:                                               │
│                                                                                 │
│ ┌─ Success Path:                                                               │
│ │  VR.Status.State = "Primary"/"Secondary"                                     │
│ │  VR.Status.Conditions = [{Type: "Completed", Status: "True"}]                │
│ │  VR.Status.LastSyncTime = "2024-01-15T10:30:00Z"                            │
│ │                                                                               │
│ └─ Error Path:                                                                │
│    VR.Status.Conditions = [{                                                   │
│      Type: "Degraded",                                                         │
│      Status: "True",                                                           │
│      Reason: "ReplicationFailed",                                              │
│      Message: "Failed to promote volume: rbd command timeout"                  │
│    }]                                                                          │
│                                                                                 │
│ Retry Strategy:                                                                 │
│ ├─ Exponential backoff: 1s → 2s → 4s → 8s → 16s → 30s (max)                 │
│ ├─ Max retries: 10                                                            │
│ ├─ Permanent failures: Authentication, not found                               │
│ └─ Temporary failures: Network timeout, Ceph cluster busy                      │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

## Why PVC/PV Are NOT Replicated

### 1. **Different Cluster Contexts**
- PV/PVC are cluster-specific Kubernetes resources
- Each cluster has its own API server and etcd
- No automatic cross-cluster Kubernetes resource replication

### 2. **Storage vs. Control Plane Separation**
- **Control Plane (Kubernetes)**: PVC, PV, VolumeReplication objects
- **Data Plane (Ceph)**: Actual storage blocks, RBD images
- Ceph handles data replication, Kubernetes handles orchestration

### 3. **Failover Flexibility**
- During failover, DR2 needs to create **new** PVC/PV specific to its cluster
- PV names, UIDs, and references must be unique to DR2
- Allows for different configurations (storage class, access modes, etc.)

## Failover Process

### Step 1: Pre-Failover State
```
DR1: PVC → PV → RBD image (primary, read/write)
                    ↓ (mirroring)
DR2:            RBD image (secondary, read-only)
```

### Step 2: Demote DR1 (if accessible)
```bash
kubectl --context=dr1 patch volumereplication test-volume-replication \
  --type=merge -p '{"spec":{"replicationState":"secondary"}}'
```
Result: DR1 RBD image becomes secondary

### Step 3: Promote DR2
```bash
kubectl --context=dr2 patch volumereplication test-volume-replication \
  --type=merge -p '{"spec":{"replicationState":"primary"}}'
```
Result: DR2 RBD image becomes primary (read/write)

### Step 4: Create PVC/PV on DR2
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-replication-pvc  # Same name as DR1
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: rook-ceph-block
  # CSI driver will bind to the existing RBD image
```

### Step 5: Post-Failover State
```
DR1:            RBD image (secondary, read-only)
                    ↑ (reverse mirroring)
DR2: PVC → PV → RBD image (primary, read/write)
```

## Test Verification

The enhanced test script verifies this model:

```bash
make test-csi-replication
```

### Expected Output

```
8. Verifying what SHOULD and SHOULD NOT exist on DR2...

=== Kubernetes Objects (should NOT exist on DR2 during replication) ===

Checking VolumeReplication on DR2 (should NOT exist):
  ✓ Correct: No VolumeReplication on DR2

Checking PVC on DR2 (should NOT exist):
  ✓ Correct: PVC 'test-replication-pvc' does not exist on DR2

Checking PV on DR2 (should NOT exist):
  ✓ Correct: PV pvc-xxxx does not exist on DR2

=== Storage Layer (SHOULD exist on DR2 via RBD mirroring) ===

Explanation:
  During normal replication:
    • Kubernetes objects (PVC/PV/VR) exist ONLY on primary cluster (DR1)
    • RBD image data is replicated to DR2 via Ceph mirroring
    • During failover, DR2 would create NEW PVC/PV pointing to replicated RBD image
```

## Ramen DR Orchestration

Ramen automates this process:

1. **DRPlacementControl** resource declares desired cluster
2. Ramen detects failover intent
3. Ramen:
   - Demotes volumes on source cluster
   - Promotes volumes on target cluster
   - Recreates PVC/PV on target cluster
   - Updates application placement

## Common Misconceptions

### ❌ "PVC should be visible on DR2"
**Wrong.** Only RBD image is replicated. PVC is cluster-specific.

### ❌ "VolumeReplication should exist on both clusters"
**Wrong.** VolumeReplication exists only on the cluster with the primary volume.

### ❌ "I need to manually copy PVC/PV to DR2"
**Wrong.** During failover, new PVC/PV are created that bind to the replicated RBD image.

### ✅ "Only the RBD image data is replicated"
**Correct.** Ceph handles block-level replication. Kubernetes objects are recreated during failover.

## Verification Commands

### Check DR1 (Primary)
```bash
# Kubernetes objects
kubectl --context=dr1 get pvc test-replication-pvc
kubectl --context=dr1 get pv
kubectl --context=dr1 get volumereplication

# Storage layer
kubectl --context=dr1 -n rook-ceph exec -it deploy/rook-ceph-tools -- \
  rbd ls replicapool
kubectl --context=dr1 -n rook-ceph exec -it deploy/rook-ceph-tools -- \
  rbd mirror image status replicapool/<image-name>
```

### Check DR2 (Secondary)
```bash
# Kubernetes objects (should be empty)
kubectl --context=dr2 get pvc test-replication-pvc  # Not found
kubectl --context=dr2 get volumereplication          # Empty

# Storage layer (should have replicated image)
kubectl --context=dr2 -n rook-ceph exec -it deploy/rook-ceph-tools -- \
  rbd ls replicapool  # Should show replicated image
kubectl --context=dr2 -n rook-ceph exec -it deploy/rook-ceph-tools -- \
  rbd mirror image status replicapool/<image-name>  # up+replaying
```

## Summary

| Component | DR1 (Primary) | DR2 (Secondary) | Notes |
|-----------|---------------|-----------------|-------|
| PVC | ✅ Exists | ❌ Does not exist | Created during failover |
| PV | ✅ Exists | ❌ Does not exist | Created during failover |
| VolumeReplication | ✅ Exists (Primary) | ❌ Does not exist | Primary-only resource |
| RBD Image (data) | ✅ Primary (R/W) | ✅ Replica (R/O) | Replicated by Ceph |
| RBD Mirror Status | up+stopped | up+replaying | Healthy replication |

**Key Takeaway:** Replication happens at the **storage layer** (Ceph), not the **Kubernetes layer**. PVC/PV are recreated during failover to bind to the replicated storage.
