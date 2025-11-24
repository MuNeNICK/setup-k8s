#!/bin/bash

# Launch a lightweight web UI that collects installation options and
# maps them to the regular CLI variables.
run_gui_installer() {
    if ! command -v python3 >/dev/null 2>&1; then
        echo "Error: --gui option requires python3 to be installed." >&2
        exit 1
    fi

    local bind_addr="${GUI_BIND_ADDRESS:-127.0.0.1}"
    local gui_port="${GUI_PORT:-8080}"

    echo "Launching setup-k8s web installer at http://${bind_addr}:${gui_port}"
    echo "Complete the form in your browser to continue. Press Ctrl+C to cancel."

    local gui_output
    if ! gui_output=$(
        python3 - "$bind_addr" "$gui_port" <<'PYTHON'
import http.server
import socketserver
import sys
import threading
import urllib.parse

BIND_ADDR = sys.argv[1]
PORT = int(sys.argv[2])

INDEX_PAGE = """<!DOCTYPE html>
<html lang=\"en\">
<head>
<meta charset=\"utf-8\">
<title>setup-k8s Web Installer</title>
<style>
body { font-family: -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; background: #f4f5f7; margin: 0; padding: 0; color: #1f2933; }
.wrapper { max-width: 760px; margin: 40px auto; background: #fff; padding: 32px; border-radius: 12px; box-shadow: 0 10px 20px rgba(15,23,42,0.08); }
h1 { margin-top: 0; }
form { margin-top: 24px; }
.grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 16px; }
label { display: flex; flex-direction: column; font-size: 14px; font-weight: 600; gap: 6px; }
input[type="text"], select { padding: 10px; font-size: 14px; border: 1px solid #cbd5e1; border-radius: 6px; }
input[type="checkbox"] { margin-right: 8px; }
.card { border: 1px solid #e2e8f0; border-radius: 10px; padding: 16px; margin-top: 20px; background: #f8fafc; }
.card h3 { margin-top: 0; }
.actions { margin-top: 24px; }
button { background: #2563eb; color: #fff; border: none; padding: 12px 24px; border-radius: 6px; font-size: 15px; cursor: pointer; }
button:hover { background: #1d4ed8; }
.hint { margin-top: 16px; font-size: 13px; color: #475467; }
.note { font-size: 13px; color: #475467; margin-bottom: 8px; }
</style>
<script>
function updateWorkerFields() {
  var select = document.getElementById('node_type');
  var worker = document.getElementById('worker-fields');
  if (!select || !worker) { return; }
  worker.style.display = select.value === 'worker' ? 'block' : 'none';
}
document.addEventListener('DOMContentLoaded', updateWorkerFields);
</script>
</head>
<body>
<div class=\"wrapper\">
  <h1>setup-k8s Web Installer</h1>
  <p class=\"note\">Fill out the form and submit to kick off the installation from this terminal session.</p>
  <form method=\"post\">
    <div class=\"grid\">
      <label>Node type
        <select name=\"node_type\" id=\"node_type\" onchange=\"updateWorkerFields()\">
          <option value=\"master\" selected>Master (control plane)</option>
          <option value=\"worker\">Worker</option>
        </select>
      </label>
      <label>Container runtime
        <select name=\"cri\">
          <option value=\"containerd\" selected>containerd</option>
          <option value=\"crio\">CRI-O</option>
        </select>
      </label>
      <label>Kubernetes minor version
        <input type=\"text\" name=\"kubernetes_version\" placeholder=\"1.31\">
      </label>
      <label>Proxy mode
        <select name=\"proxy_mode\">
          <option value=\"iptables\" selected>iptables</option>
          <option value=\"ipvs\">ipvs</option>
          <option value=\"nftables\">nftables (1.29+)</option>
        </select>
      </label>
      <label>Pod network CIDR
        <input type=\"text\" name=\"pod_network_cidr\" value=\"192.168.0.0/16\">
      </label>
      <label>Service CIDR
        <input type=\"text\" name=\"service_cidr\" value=\"10.96.0.0/12\">
      </label>
      <label>API server advertise address
        <input type=\"text\" name=\"apiserver_advertise_address\" placeholder=\"192.168.1.10\">
      </label>
      <label>Control plane endpoint
        <input type=\"text\" name=\"control_plane_endpoint\" placeholder=\"cluster.example.com\">
      </label>
    </div>

    <div id=\"worker-fields\" class=\"card\" style=\"display:none;\">
      <h3>Worker join information</h3>
      <p class=\"note\">Provide the kubeadm join information from the control-plane node.</p>
      <div class=\"grid\">
        <label>Join token
          <input type=\"text\" name=\"join_token\" placeholder=\"abcdef.0123456789abcdef\">
        </label>
        <label>Join address
          <input type=\"text\" name=\"join_address\" placeholder=\"192.168.1.10:6443\">
        </label>
        <label>Discovery token hash
          <input type=\"text\" name=\"discovery_token_hash\" placeholder=\"sha256:...\">
        </label>
      </div>
    </div>

    <div class=\"card\">
      <h3>Extras</h3>
      <p class=\"note\">Optional helpers that mirror the CLI flags.</p>
      <input type=\"hidden\" name=\"enable_completion\" value=\"false\">
      <label style=\"flex-direction:row; align-items:center; font-weight:500;\">
        <input type=\"checkbox\" name=\"enable_completion\" value=\"true\" checked> Configure kubectl shell completion
      </label>
      <label>Completion shells
        <select name=\"completion_shells\">
          <option value=\"auto\" selected>Auto detect</option>
          <option value=\"bash\">bash</option>
          <option value=\"zsh\">zsh</option>
          <option value=\"fish\">fish</option>
        </select>
      </label>
      <input type=\"hidden\" name=\"install_helm\" value=\"false\">
      <label style=\"flex-direction:row; align-items:center; font-weight:500;\">
        <input type=\"checkbox\" name=\"install_helm\" value=\"true\"> Install Helm CLI
      </label>
    </div>

    <div class=\"actions\">
      <button type=\"submit\">Start installation</button>
    </div>
  </form>
  <p class=\"hint\">This local server stops automatically after submission.</p>
</div>
</body>
</html>
"""

SUCCESS_PAGE = """<!DOCTYPE html>
<html lang=\"en\">
<head><meta charset=\"utf-8\"><title>setup-k8s</title>
<style>body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;background:#f4f5f7;color:#1f2933;display:flex;align-items:center;justify-content:center;height:100vh;} .card{background:#fff;padding:32px;border-radius:12px;box-shadow:0 10px 20px rgba(15,23,42,0.08);text-align:center;} a{color:#2563eb;text-decoration:none;}</style>
</head>
<body><div class=\"card\"><h2>Configuration received</h2><p>You can close this tab and return to the terminal.</p></div></body></html>"""

FIELDS = [
    "NODE_TYPE",
    "CRI",
    "PROXY_MODE",
    "K8S_VERSION",
    "POD_NETWORK_CIDR",
    "SERVICE_CIDR",
    "APISERVER_ADVERTISE_ADDRESS",
    "CONTROL_PLANE_ENDPOINT",
    "JOIN_TOKEN",
    "JOIN_ADDRESS",
    "DISCOVERY_TOKEN_HASH",
    "ENABLE_COMPLETION",
    "COMPLETION_SHELLS",
    "INSTALL_HELM",
]


def normalize(form):
    def get(name, default=""):
        value = form.get(name, "").strip()
        if value:
            return value
        return default

    def bool_value(name, default="false"):
        value = form.get(name, default).strip().lower()
        return "true" if value == "true" else "false"

    return {
        "NODE_TYPE": get("node_type", "master") or "master",
        "CRI": get("cri", "containerd") or "containerd",
        "PROXY_MODE": get("proxy_mode", "iptables") or "iptables",
        "K8S_VERSION": get("kubernetes_version", ""),
        "POD_NETWORK_CIDR": get("pod_network_cidr", ""),
        "SERVICE_CIDR": get("service_cidr", ""),
        "APISERVER_ADVERTISE_ADDRESS": get("apiserver_advertise_address", ""),
        "CONTROL_PLANE_ENDPOINT": get("control_plane_endpoint", ""),
        "JOIN_TOKEN": get("join_token", ""),
        "JOIN_ADDRESS": get("join_address", ""),
        "DISCOVERY_TOKEN_HASH": get("discovery_token_hash", ""),
        "ENABLE_COMPLETION": bool_value("enable_completion", "true"),
        "COMPLETION_SHELLS": get("completion_shells", "auto") or "auto",
        "INSTALL_HELM": bool_value("install_helm", "false"),
    }


class InstallerHandler(http.server.BaseHTTPRequestHandler):
    def send_html(self, body, status=200):
        data = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.send_html(INDEX_PAGE)

    def do_POST(self):
        try:
            size = int(self.headers.get("Content-Length", 0))
        except (TypeError, ValueError):
            size = 0
        raw = self.rfile.read(size).decode("utf-8")
        parsed = urllib.parse.parse_qs(raw, keep_blank_values=True)
        flat = {k: v[-1] for k, v in parsed.items()}
        self.server.selection = normalize(flat)
        self.send_html(SUCCESS_PAGE)
        threading.Thread(target=self.server.shutdown, daemon=True).start()

    def log_message(self, fmt, *args):  # noqa: D401 (silence default spam)
        sys.stderr.write("%s - - [%s] %s\n" % (self.address_string(), self.log_date_time_string(), fmt % args))


class ThreadingServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    try:
        httpd = ThreadingServer((BIND_ADDR, PORT), InstallerHandler)
    except OSError as exc:
        sys.stderr.write(f"Failed to start web installer: {exc}\n")
        sys.exit(2)

    selection = None
    try:
        sys.stderr.write(f"Web installer running at http://{BIND_ADDR}:{PORT}\n")
        httpd.selection = None
        httpd.serve_forever()
        selection = httpd.selection
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()

    if not selection:
        sys.exit(1)

    for field in FIELDS:
        value = selection.get(field, "") or ""
        print(f"{field}={value}")


if __name__ == "__main__":
    main()
PYTHON
    ); then
        echo "GUI installer aborted or failed before receiving configuration." >&2
        exit 1
    fi

    if [ -z "$gui_output" ]; then
        echo "GUI installer returned no configuration." >&2
        exit 1
    fi

    local gui_pod_network_cidr=""
    local gui_service_cidr=""
    local gui_api_addr=""
    local gui_cp_endpoint=""

    while IFS='=' read -r key value; do
        value=${value%$'\r'}
        case "$key" in
            NODE_TYPE)
                NODE_TYPE="$value"
                ;;
            CRI)
                CRI="$value"
                ;;
            PROXY_MODE)
                PROXY_MODE="$value"
                ;;
            K8S_VERSION)
                K8S_VERSION="$value"
                if [ -n "$value" ]; then
                    K8S_VERSION_USER_SET="true"
                fi
                ;;
            POD_NETWORK_CIDR)
                gui_pod_network_cidr="$value"
                ;;
            SERVICE_CIDR)
                gui_service_cidr="$value"
                ;;
            APISERVER_ADVERTISE_ADDRESS)
                gui_api_addr="$value"
                ;;
            CONTROL_PLANE_ENDPOINT)
                gui_cp_endpoint="$value"
                ;;
            JOIN_TOKEN)
                JOIN_TOKEN="$value"
                ;;
            JOIN_ADDRESS)
                JOIN_ADDRESS="$value"
                ;;
            DISCOVERY_TOKEN_HASH)
                DISCOVERY_TOKEN_HASH="$value"
                ;;
            ENABLE_COMPLETION)
                ENABLE_COMPLETION="$value"
                ;;
            COMPLETION_SHELLS)
                COMPLETION_SHELLS="$value"
                ;;
            INSTALL_HELM)
                INSTALL_HELM="$value"
                ;;
        esac
    done <<< "$gui_output"

    if [ -n "$gui_pod_network_cidr" ]; then
        KUBEADM_ARGS="$KUBEADM_ARGS --pod-network-cidr $gui_pod_network_cidr"
    fi
    if [ -n "$gui_service_cidr" ]; then
        KUBEADM_ARGS="$KUBEADM_ARGS --service-cidr $gui_service_cidr"
    fi
    if [ -n "$gui_api_addr" ]; then
        KUBEADM_ARGS="$KUBEADM_ARGS --apiserver-advertise-address $gui_api_addr"
    fi
    if [ -n "$gui_cp_endpoint" ]; then
        KUBEADM_ARGS="$KUBEADM_ARGS --control-plane-endpoint $gui_cp_endpoint"
    fi
}
