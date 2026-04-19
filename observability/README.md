# Observability Stack — Grafana + InfluxDB + Telegraf

Minimal Docker Compose stack for ingesting Cisco IOS-XE model-driven telemetry
(MDT) and visualising it in Grafana.

```
Cisco IOS-XE ──[gRPC dial-out :57000]──> Telegraf ──> InfluxDB :8086 ──> Grafana :3001
```

**Files used:**
[`docker-compose.yml`](../observability/docker-compose.yml) ·
[`telegraf/telegraf.conf`](../observability/telegraf/telegraf.conf) ·
[`README.md` (raw)](../observability/README.md)

All three services run from official upstream images; no custom Dockerfile.
Volumes are tagged `:z` for SELinux-enforcing hosts (Fedora, RHEL).

## 1. Bring the stack up

Clone the repo (if you haven't already), then start the three containers:

```bash
git clone https://github.com/klimpsch/devops-infrastructure.git
cd devops-infrastructure/observability
docker compose up -d
docker compose ps                # all three should be "running"
```

Prefer a smaller checkout? Use a sparse clone — only the observability folder:

```bash
git clone --depth 1 --filter=blob:none --sparse https://github.com/klimpsch/devops-infrastructure.git
cd devops-infrastructure
git sparse-checkout set observability
cd observability && docker compose up -d
```

Ports:

| Service  | Host port | Purpose                                |
|----------|-----------|----------------------------------------|
| Grafana  | 3001      | Web UI — http://localhost:3001         |
| InfluxDB | 8086      | API + web UI — http://localhost:8086   |
| Telegraf | 57000     | Cisco gRPC dial-out listener           |

Default credentials (change for anything non-lab):

- Grafana: `admin` / `admin`
- InfluxDB: `admin` / `adminpassword`, org `myorg`, bucket `telegraf`, token `my-super-secret-auth-token`

## 2. Configure a Cisco IOS-XE device to dial out

On each router/switch that should push telemetry, define subscriptions whose
`receiver ip address` points at the host running Telegraf on port 57000.

Replace **`<COLLECTOR_IP>`** below with the IP of the Docker host reachable
from the device, and **`<DEVICE_MGMT_IP>`** with the source interface IP on
the device (the receiver uses this to identify the stream).

```cisco
! Enable NETCONF / model-driven programmability
netconf-yang

! CPU utilisation — five-second average, pushed every 3 s
telemetry ietf subscription 101
 encoding encode-kvgpb
 filter xpath /process-cpu-ios-xe-oper:cpu-usage/cpu-utilization/five-seconds
 stream yang-push
 update-policy periodic 3000
 source-address <DEVICE_MGMT_IP>
 receiver ip address <COLLECTOR_IP> 57000 protocol grpc-tcp

! Memory usage — every 6 s
telemetry ietf subscription 102
 encoding encode-kvgpb
 filter xpath /memory-ios-xe-oper:memory-statistics/memory-statistic
 stream yang-push
 update-policy periodic 6000
 source-address <DEVICE_MGMT_IP>
 receiver ip address <COLLECTOR_IP> 57000 protocol grpc-tcp

! Interface counters — every 3 s
telemetry ietf subscription 103
 encoding encode-kvgpb
 filter xpath /interfaces-ios-xe-oper:interfaces/interface
 stream yang-push
 update-policy periodic 3000
 source-address <DEVICE_MGMT_IP>
 receiver ip address <COLLECTOR_IP> 57000 protocol grpc-tcp
```

Subscription IDs `101`–`106` in the router config must match the aliases in
`telegraf/telegraf.conf` so measurements land with friendly names (`cpu`,
`memory`, `interfaces`, `cdp`, `ospf_interfaces`, `ospf_neighbors`).

Two more ready-to-paste templates for OSPF and CDP:

```cisco
telemetry ietf subscription 104
 encoding encode-kvgpb
 filter xpath /cdp-ios-xe-oper:cdp-neighbor-details/cdp-neighbor-detail
 stream yang-push
 update-policy periodic 60000
 source-address <DEVICE_MGMT_IP>
 receiver ip address <COLLECTOR_IP> 57000 protocol grpc-tcp

telemetry ietf subscription 105
 encoding encode-kvgpb
 filter xpath /ospf-ios-xe-oper:ospf-oper-data/ospf-state/ospf-instance/ospf-area/ospf-interface
 stream yang-push
 update-policy periodic 10000
 source-address <DEVICE_MGMT_IP>
 receiver ip address <COLLECTOR_IP> 57000 protocol grpc-tcp
```

Verify on the device:

```
show telemetry ietf subscription all
show telemetry connection all        ! "Active" state = collector reached
```

## 3. Confirm telemetry is flowing

### 3a. Telegraf is listening

```bash
docker compose logs telegraf | grep -i "Starting .*cisco_telemetry_mdt"
# expect: Started input cisco_telemetry_mdt on :57000
```

### 3b. InfluxDB has data

Using the `influx` CLI inside the InfluxDB container:

```bash
docker compose exec influxdb influx query \
  --token my-super-secret-auth-token \
  --org myorg \
  'import "influxdata/influxdb/schema"
   schema.measurements(bucket: "telegraf")'
```

Once a device starts dialling out you should see measurements like
`Cisco-IOS-XE-process-cpu-oper:cpu-usage/cpu-utilization` appear.

Or query straight from your workstation:

```bash
curl -s --request POST "http://localhost:8086/api/v2/query?org=myorg" \
  --header "Authorization: Token my-super-secret-auth-token" \
  --header "Content-Type: application/vnd.flux" \
  --data 'from(bucket: "telegraf")
          |> range(start: -5m)
          |> filter(fn: (r) => r._measurement =~ /cpu-usage/)
          |> last()'
```

### 3c. Wire Grafana to InfluxDB

1. Open http://localhost:3001 → log in (`admin` / `admin`, skip password change for a lab).
2. **Connections → Data sources → Add data source → InfluxDB**.
3. Settings:
   - Query language: **Flux**
   - URL: `http://influxdb:8086`  *(container-to-container DNS)*
   - Organization: `myorg`
   - Token: `my-super-secret-auth-token`
   - Default bucket: `telegraf`
4. **Save & test** — should return *"datasource is working"*.

From there you can build panels with Flux queries against the `telegraf`
bucket, or import a pre-built Cisco MDT dashboard from
[grafana.com/dashboards](https://grafana.com/grafana/dashboards/).

## 4. Useful Flux queries

Paste these into **Grafana → panel → Flux query editor**, or into the
InfluxDB Data Explorer at http://localhost:8086. The `v.timeRangeStart` /
`v.timeRangeStop` / `v.windowPeriod` variables are provided by Grafana; when
running from the Data Explorer, swap them for literals like `-15m` and `1m`.

### Discover what's in the bucket

```flux
import "influxdata/influxdb/schema"
schema.measurements(bucket: "telegraf")
```

### CPU utilisation (latest snapshot)

```flux
from(bucket: "telegraf")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "Cisco-IOS-XE-process-cpu-oper:cpu-usage/cpu-utilization")
  |> filter(fn: (r) => r._field == "five_seconds")
  |> last()
```

### CPU utilisation over time (5-sec, 1-min, 5-min averages)

```flux
from(bucket: "telegraf")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "Cisco-IOS-XE-process-cpu-oper:cpu-usage/cpu-utilization")
  |> filter(fn: (r) => r._field == "five_seconds" or r._field == "one_minute" or r._field == "five_minutes")
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)
```

### Memory (used / free / total)

```flux
from(bucket: "telegraf")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "Cisco-IOS-XE-memory-oper:memory-statistics/memory-statistic")
  |> filter(fn: (r) => r._field == "used_memory" or r._field == "free_memory" or r._field == "total_memory")
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)
```

### Interface traffic (bytes/sec)

Counters are monotonically increasing — `derivative` converts them into a
rate. `nonNegative: true` swallows counter resets.

```flux
// Inbound
from(bucket: "telegraf")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "Cisco-IOS-XE-interfaces-oper:interfaces/interface")
  |> filter(fn: (r) => r._field == "statistics/in_octets")
  |> derivative(unit: 1s, nonNegative: true)
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)

// Outbound — swap in_octets → out_octets
```

### Interface errors (drops / errors / per second)

```flux
from(bucket: "telegraf")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "Cisco-IOS-XE-interfaces-oper:interfaces/interface")
  |> filter(fn: (r) => r._field == "statistics/in_errors" or r._field == "statistics/out_errors")
  |> derivative(unit: 1s, nonNegative: true)
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)
```

### Interface status table (great for a Grafana "table" panel)

```flux
from(bucket: "telegraf")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "Cisco-IOS-XE-interfaces-oper:interfaces/interface")
  |> filter(fn: (r) => r._field == "oper_status" or r._field == "speed" or r._field == "mtu")
  |> last()
  |> pivot(rowKey: ["_time", "name"], columnKey: ["_field"], valueColumn: "_value")
  |> map(fn: (r) => ({
      interface:   r.name,
      oper_status: r.oper_status,
      speed_Mbps:  float(v: r.speed) / 1000000.0,
      mtu:         r.mtu
  }))
  |> drop(columns: ["_time", "_start", "_stop", "source", "host", "path", "subscription"])
```

### OSPF neighbor state

```flux
from(bucket: "telegraf")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "Cisco-IOS-XE-ospf-oper:ospf-oper-data/ospf-state/ospf-instance/ospf-area/ospf-interface/ospf-neighbor")
  |> last()
  |> pivot(rowKey: ["_time"], columnKey: ["_field"], valueColumn: "_value")
```

### Handy pattern: everything from the last device you heard from

Useful when sanity-checking that dial-out is working for a specific source
IP. Replace `192.168.122.197` with your device's `source-address`.

```flux
from(bucket: "telegraf")
  |> range(start: -5m)
  |> filter(fn: (r) => r.source == "192.168.122.197")
  |> group(columns: ["_measurement"])
  |> count()
```

## 5. Teardown

```bash
docker compose down              # stop, keep data
docker compose down -v           # stop AND wipe influxdb/grafana volumes
```

## Troubleshooting

| Symptom                                   | Most likely cause                                                     |
|-------------------------------------------|------------------------------------------------------------------------|
| `telemetry connection` shows *Connecting* | firewall between device and collector on 57000/tcp                    |
| Telegraf logs show TLS handshake errors   | device config specifies `protocol grpc-tcp` but telegraf has TLS on   |
| No measurements in InfluxDB               | subscription `receiver ip` typo, or source-address not routable       |
| Grafana can't reach InfluxDB              | use `http://influxdb:8086` (container name), not `http://localhost`   |
| SELinux denies volume mounts              | confirm `:z` suffix on volumes and `setenforce 0` isn't hiding the bug|
