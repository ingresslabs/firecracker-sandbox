#!/usr/bin/env python3
"""
Kubernetes Firecracker Test Environment

This script automates the creation of a Firecracker sandbox environment
for testing Kubernetes packages built in the output directory.
"""

import argparse
import json
import logging
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Dict, List, Optional, Tuple

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)

# Default paths
DEFAULT_OUTPUT_DIR = "/srv/k8s-release/output"
DEFAULT_FIRECRACKER_PATH = "/usr/local/bin/firecracker"
DEFAULT_KERNEL_PATH = "/var/lib/firecracker/vmlinux"
DEFAULT_ROOTFS_PATH = "/var/lib/firecracker/rootfs.ext4"
DEFAULT_SOCKET_PATH = "/tmp/firecracker.socket"
DEFAULT_TAP_DEVICE = "tap0"
DEFAULT_VM_IP = "172.16.0.2"
DEFAULT_HOST_IP = "172.16.0.1"

class Colors:
    """Terminal colors for pretty output"""
    HEADER = '\033[95m'
    BLUE = '\033[94m'
    GREEN = '\033[92m'
    YELLOW = '\033[93m'
    RED = '\033[91m'
    ENDC = '\033[0m'
    BOLD = '\033[1m'
    UNDERLINE = '\033[4m'

def print_color(message: str, color: str) -> None:
    """Print colored message to terminal"""
    print(f"{color}{message}{Colors.ENDC}")

def run_command(cmd: List[str], cwd: Optional[str] = None, 
                shell: bool = False, check: bool = True) -> Tuple[int, str, str]:
    """Run a command and return exit code, stdout, and stderr"""
    if shell:
        cmd_str = " ".join(cmd)
        logger.debug(f"Running shell command: {cmd_str}")
        process = subprocess.Popen(
            cmd_str, shell=True, stdout=subprocess.PIPE, 
            stderr=subprocess.PIPE, cwd=cwd, text=True
        )
    else:
        logger.debug(f"Running command: {cmd}")
        process = subprocess.Popen(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, 
            cwd=cwd, text=True
        )
    
    stdout, stderr = process.communicate()
    exit_code = process.returncode
    
    if check and exit_code != 0:
        logger.error(f"Command failed with exit code {exit_code}")
        logger.error(f"Command: {cmd}")
        logger.error(f"STDOUT: {stdout}")
        logger.error(f"STDERR: {stderr}")
        raise subprocess.CalledProcessError(exit_code, cmd, stdout, stderr)
    
    return exit_code, stdout, stderr

def find_firecracker_path() -> str:
    """Find the path to the Firecracker binary"""
    try:
        result = subprocess.run(["which", "firecracker"], 
                               check=True, stdout=subprocess.PIPE, 
                               stderr=subprocess.PIPE, text=True)
        path = result.stdout.strip()
        logger.info(f"Found Firecracker at: {path}")
        return path
    except subprocess.CalledProcessError:
        logger.warning("Could not find Firecracker in PATH")
        # Check common locations
        common_paths = [
            "/usr/local/bin/firecracker",
            "/usr/bin/firecracker",
            "/bin/firecracker"
        ]
        for path in common_paths:
            if os.path.isfile(path) and os.access(path, os.X_OK):
                logger.info(f"Found Firecracker at: {path}")
                return path
        
        return DEFAULT_FIRECRACKER_PATH

def check_dependencies() -> bool:
    """Check if required dependencies are installed"""
    dependencies = ["firecracker", "ip", "brctl", "dpkg", "curl", "wget"]
    missing = []
    
    for dep in dependencies:
        try:
            subprocess.run(["which", dep], check=True, 
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        except subprocess.CalledProcessError:
            missing.append(dep)
    
    if missing:
        print_color(f"Missing dependencies: {', '.join(missing)}", Colors.RED)
        print_color("Please install the missing dependencies and try again.", Colors.YELLOW)
        return False
    
    return True

def setup_network(tap_device: str, host_ip: str) -> bool:
    """Set up network bridge and tap device for VM"""
    try:
        print_color("Setting up network interfaces...", Colors.BLUE)
        
        # Clean up any existing network setup first
        cleanup_network(tap_device)
        
        # Check if br0 exists and remove it if it does
        _, stdout, _ = run_command(["ip", "link", "show", "br0"], check=False)
        if "br0" in stdout:
            print_color("Removing existing br0 bridge", Colors.YELLOW)
            run_command(["ip", "link", "set", "dev", "br0", "down"], check=False)
            run_command(["brctl", "delbr", "br0"], check=False)
        
        # Create bridge
        print_color("Creating bridge br0", Colors.BLUE)
        run_command(["brctl", "addbr", "br0"])
        run_command(["ip", "addr", "add", f"{host_ip}/24", "dev", "br0"])
        run_command(["ip", "link", "set", "dev", "br0", "up"])
        
        # Create tap device
        print_color(f"Creating tap device {tap_device}", Colors.BLUE)
        _, stdout, _ = run_command(["ip", "link", "show", tap_device], check=False)
        if tap_device in stdout:
            print_color(f"Removing existing {tap_device}", Colors.YELLOW)
            run_command(["ip", "link", "set", "dev", tap_device, "down"], check=False)
            run_command(["ip", "tuntap", "del", "dev", tap_device, "mode", "tap"], check=False)
        
        run_command(["ip", "tuntap", "add", "dev", tap_device, "mode", "tap"])
        
        # Add tap to bridge
        print_color(f"Adding {tap_device} to bridge br0", Colors.BLUE)
        run_command(["brctl", "addif", "br0", tap_device])
        run_command(["ip", "link", "set", "dev", tap_device, "up"])
        
        # Enable IP forwarding
        print_color("Enabling IP forwarding", Colors.BLUE)
        run_command(["sysctl", "-w", "net.ipv4.ip_forward=1"])
        
        # Set up iptables for NAT if needed
        print_color("Setting up NAT for VM traffic", Colors.BLUE)
        # Get default interface
        _, stdout, _ = run_command(["ip", "route", "get", "8.8.8.8"], check=False)
        default_iface = None
        for word in stdout.split():
            if word.startswith("dev"):
                default_iface = stdout.split()[stdout.split().index(word) + 1]
                break
        
        if default_iface and default_iface != "br0":
            print_color(f"Setting up NAT using {default_iface}", Colors.BLUE)
            # Enable NAT
            run_command(["iptables", "-t", "nat", "-A", "POSTROUTING", "-o", default_iface, "-j", "MASQUERADE"], check=False)
            run_command(["iptables", "-A", "FORWARD", "-i", default_iface, "-o", "br0", "-m", "state", "--state", "RELATED,ESTABLISHED", "-j", "ACCEPT"], check=False)
            run_command(["iptables", "-A", "FORWARD", "-i", "br0", "-o", default_iface, "-j", "ACCEPT"], check=False)
        
        # Display network configuration for debugging
        print_color("Network configuration:", Colors.BLUE)
        _, stdout, _ = run_command(["ip", "addr", "show", "br0"], check=False)
        print(stdout)
        _, stdout, _ = run_command(["ip", "addr", "show", tap_device], check=False)
        print(stdout)
        _, stdout, _ = run_command(["brctl", "show"], check=False)
        print(stdout)
        
        return True
    except subprocess.CalledProcessError as e:
        logger.error(f"Failed to set up network: {e}")
        return False

def create_firecracker_config(
    kernel_path: str,
    rootfs_path: str,
    socket_path: str,
    tap_device: str,
    vm_ip: str,
    host_ip: str,
    vcpu_count: int = 2,
    mem_size_mib: int = 2048
) -> Dict:
    """Create Firecracker VM configuration"""
    # Calculate gateway and netmask
    gateway = host_ip
    netmask = "255.255.255.0"
    
    return {
        "boot-source": {
            "kernel_image_path": kernel_path,
            "boot_args": f"console=ttyS0 reboot=k panic=1 pci=off ip={vm_ip}::{gateway}:{netmask}::eth0:on root=/dev/vda rw"
        },
        "drives": [
            {
                "drive_id": "rootfs",
                "path_on_host": rootfs_path,
                "is_root_device": True,
                "is_read_only": False
            }
        ],
        "machine-config": {
            "vcpu_count": vcpu_count,
            "mem_size_mib": mem_size_mib,
            "ht_enabled": False
        },
        "network-interfaces": [
            {
                "iface_id": "eth0",
                "guest_mac": "AA:FC:00:00:00:01",
                "host_dev_name": tap_device
            }
        ],
        "vsock": {
            "vsock_id": "vsock0",
            "guest_cid": 3,
            "uds_path": "/tmp/vsock.sock"
        },
        "logger": {
            "log_path": "/tmp/firecracker.log",
            "level": "Debug",
            "show_level": True,
            "show_log_origin": True
        }
    }

def start_firecracker_vm(config: Dict, socket_path: str) -> subprocess.Popen:
    """Start Firecracker VM with the given configuration"""
    # Remove socket if it exists
    if os.path.exists(socket_path):
        os.unlink(socket_path)
    
    # Remove log file if it exists
    log_path = "/tmp/firecracker.log"
    if os.path.exists(log_path):
        os.unlink(log_path)
    
    # Start Firecracker process
    firecracker_cmd = [DEFAULT_FIRECRACKER_PATH, "--api-sock", socket_path, "--level", "Debug"]
    print_color(f"Starting Firecracker with command: {' '.join(firecracker_cmd)}", Colors.BLUE)
    
    firecracker_process = subprocess.Popen(
        firecracker_cmd, 
        stdout=subprocess.PIPE, 
        stderr=subprocess.PIPE,
        text=True
    )
    
    # Wait for socket to be created
    timeout = 10
    while timeout > 0 and not os.path.exists(socket_path):
        time.sleep(0.5)
        timeout -= 0.5
    
    if not os.path.exists(socket_path):
        firecracker_process.kill()
        raise RuntimeError("Firecracker socket was not created")
    
    # Configure VM
    with tempfile.NamedTemporaryFile(mode='w', delete=False) as config_file:
        json.dump(config, config_file)
        config_path = config_file.name
    
    print_color("Configuring Firecracker VM...", Colors.BLUE)
    
    # Configure logger
    if "logger" in config:
        print_color("Setting up logger...", Colors.BLUE)
        run_command(["curl", "--unix-socket", socket_path, 
                    "-i", "-X", "PUT", "http://localhost/logger",
                    "-H", "Accept: application/json",
                    "-H", "Content-Type: application/json",
                    "-d", json.dumps(config["logger"])])
    
    # Send configuration to Firecracker
    print_color("Configuring boot source...", Colors.BLUE)
    run_command(["curl", "--unix-socket", socket_path, 
                 "-i", "-X", "PUT", "http://localhost/boot-source",
                 "-H", "Accept: application/json",
                 "-H", "Content-Type: application/json",
                 "-d", json.dumps(config["boot-source"])])
    
    print_color("Configuring rootfs...", Colors.BLUE)
    run_command(["curl", "--unix-socket", socket_path, 
                 "-i", "-X", "PUT", "http://localhost/drives/rootfs",
                 "-H", "Accept: application/json",
                 "-H", "Content-Type: application/json",
                 "-d", json.dumps(config["drives"][0])])
    
    print_color("Configuring network interface...", Colors.BLUE)
    run_command(["curl", "--unix-socket", socket_path, 
                 "-i", "-X", "PUT", "http://localhost/network-interfaces/eth0",
                 "-H", "Accept: application/json",
                 "-H", "Content-Type: application/json",
                 "-d", json.dumps(config["network-interfaces"][0])])
    
    print_color("Configuring machine...", Colors.BLUE)
    run_command(["curl", "--unix-socket", socket_path, 
                 "-i", "-X", "PUT", "http://localhost/machine-config",
                 "-H", "Accept: application/json",
                 "-H", "Content-Type: application/json",
                 "-d", json.dumps(config["machine-config"])])
    
    # Configure vsock if present
    if "vsock" in config:
        print_color("Configuring vsock...", Colors.BLUE)
        run_command(["curl", "--unix-socket", socket_path, 
                    "-i", "-X", "PUT", "http://localhost/vsock",
                    "-H", "Accept: application/json",
                    "-H", "Content-Type: application/json",
                    "-d", json.dumps(config["vsock"])])
    
    # Start VM
    print_color("Starting VM instance...", Colors.BLUE)
    run_command(["curl", "--unix-socket", socket_path, 
                 "-i", "-X", "PUT", "http://localhost/actions",
                 "-H", "Accept: application/json",
                 "-H", "Content-Type: application/json",
                 "-d", '{"action_type": "InstanceStart"}'])
    
    os.unlink(config_path)
    return firecracker_process

def copy_packages_to_vm(output_dir: str, vm_ip: str) -> bool:
    """Copy Kubernetes packages to the VM"""
    try:
        # Create a temporary directory to store packages
        with tempfile.TemporaryDirectory() as temp_dir:
            # Copy all .deb files to the temp directory
            for file in os.listdir(output_dir):
                if file.endswith(".deb"):
                    shutil.copy(os.path.join(output_dir, file), temp_dir)
            
            # Create a tarball of the packages
            tarball_path = os.path.join(temp_dir, "k8s-packages.tar.gz")
            run_command(["tar", "czf", tarball_path, "-C", temp_dir, "."])
            
            # Copy the tarball to the VM
            run_command(["scp", "-o", "StrictHostKeyChecking=no",
                        tarball_path, f"root@{vm_ip}:/tmp/"])
            
            return True
    except Exception as e:
        logger.error(f"Failed to copy packages to VM: {e}")
        return False

def install_packages_in_vm(vm_ip: str) -> bool:
    """Install Kubernetes packages in the VM"""
    try:
        # Extract packages
        run_command(["ssh", "-o", "StrictHostKeyChecking=no", 
                    f"root@{vm_ip}", "mkdir -p /tmp/k8s-packages"])
        run_command(["ssh", "-o", "StrictHostKeyChecking=no", 
                    f"root@{vm_ip}", "tar xzf /tmp/k8s-packages.tar.gz -C /tmp/k8s-packages"])
        
        # Install dependencies first
        run_command(["ssh", "-o", "StrictHostKeyChecking=no", f"root@{vm_ip}",
                    "apt-get update && apt-get install -y apt-utils systemd"])
        
        # Install packages with force-depends to handle potential dependency issues
        install_cmd = [
            "ssh", "-o", "StrictHostKeyChecking=no", f"root@{vm_ip}",
            "cd /tmp/k8s-packages && "
            "dpkg --force-depends -i etcd_*.deb etcdctl_*.deb kubernetes-ca-certs_*.deb "
            "kubernetes-service-account-certs_*.deb kubernetes-apiserver-certs_*.deb "
            "kubernetes-controller-manager-certs_*.deb kubernetes-scheduler-certs_*.deb "
            "kubernetes-node-0-certs_*.deb kubernetes-proxy-certs_*.deb "
            "kube-apiserver_*.deb kube-controller-manager_*.deb kube-scheduler_*.deb "
            "kubectl_*.deb kubelet_*.deb kube-proxy_*.deb"
        ]
        run_command(install_cmd)
        
        # Fix any broken dependencies
        run_command(["ssh", "-o", "StrictHostKeyChecking=no", f"root@{vm_ip}",
                    "apt-get install -f -y"])
        
        return True
    except Exception as e:
        logger.error(f"Failed to install packages in VM: {e}")
        return False

def configure_kubernetes_in_vm(vm_ip: str) -> bool:
    """Configure Kubernetes in the VM"""
    try:
        # Create configuration directories
        run_command(["ssh", "-o", "StrictHostKeyChecking=no", f"root@{vm_ip}",
                    "mkdir -p /etc/kubernetes/manifests /var/lib/kubelet /var/lib/etcd"])
        
        # Create basic etcd configuration
        etcd_conf = """
[Unit]
Description=etcd key-value store
Documentation=https://github.com/etcd-io/etcd

[Service]
Type=notify
ExecStart=/usr/bin/etcd --data-dir=/var/lib/etcd
Restart=always
RestartSec=10s
LimitNOFILE=40000

[Install]
WantedBy=multi-user.target
"""
        run_command(["ssh", "-o", "StrictHostKeyChecking=no", f"root@{vm_ip}",
                    f"echo '{etcd_conf}' > /etc/systemd/system/etcd.service"])
        
        # Create basic kubelet configuration
        kubelet_conf = """
[Unit]
Description=Kubernetes Kubelet
Documentation=https://kubernetes.io/docs/

[Service]
ExecStart=/usr/bin/kubelet --pod-manifest-path=/etc/kubernetes/manifests
Restart=always
StartLimitInterval=0
RestartSec=10

[Install]
WantedBy=multi-user.target
"""
        run_command(["ssh", "-o", "StrictHostKeyChecking=no", f"root@{vm_ip}",
                    f"echo '{kubelet_conf}' > /etc/systemd/system/kubelet.service"])
        
        # Reload systemd
        run_command(["ssh", "-o", "StrictHostKeyChecking=no", f"root@{vm_ip}",
                    "systemctl daemon-reload"])
        
        # Configure and start etcd
        etcd_cmd = [
            "ssh", "-o", "StrictHostKeyChecking=no", f"root@{vm_ip}",
            "systemctl enable etcd && systemctl start etcd"
        ]
        run_command(etcd_cmd)
        
        # Wait for etcd to start
        time.sleep(10)
        
        # Configure and start Kubernetes components
        k8s_cmd = [
            "ssh", "-o", "StrictHostKeyChecking=no", f"root@{vm_ip}",
            "systemctl enable kubelet kube-apiserver kube-controller-manager kube-scheduler kube-proxy && "
            "systemctl start kubelet kube-apiserver kube-controller-manager kube-scheduler kube-proxy"
        ]
        run_command(k8s_cmd, check=False)  # Don't fail if some services don't start
        
        # Wait for Kubernetes components to start
        time.sleep(20)
        
        return True
    except Exception as e:
        logger.error(f"Failed to configure Kubernetes in VM: {e}")
        return False

def test_kubernetes_cluster(vm_ip: str) -> bool:
    """Test the Kubernetes cluster"""
    try:
        # Check if Kubernetes API server is running
        _, stdout, _ = run_command(["ssh", "-o", "StrictHostKeyChecking=no", f"root@{vm_ip}",
                                  "systemctl status kube-apiserver"], check=False)
        
        if "active (running)" not in stdout:
            print_color("Kubernetes API server is not running. Checking logs...", Colors.YELLOW)
            run_command(["ssh", "-o", "StrictHostKeyChecking=no", f"root@{vm_ip}",
                        "journalctl -u kube-apiserver -n 50"], check=False)
            return False
        
        # Try to use kubectl
        print_color("Testing kubectl command...", Colors.BLUE)
        _, stdout, _ = run_command(["ssh", "-o", "StrictHostKeyChecking=no", f"root@{vm_ip}",
                                  "kubectl version --client"], check=False)
        print(stdout)
        
        # Check if we can connect to the API server
        print_color("Testing connection to API server...", Colors.BLUE)
        _, stdout, _ = run_command(["ssh", "-o", "StrictHostKeyChecking=no", f"root@{vm_ip}",
                                  "kubectl get --raw /healthz"], check=False)
        
        if "ok" in stdout:
            print_color("API server is healthy!", Colors.GREEN)
            
            # Try to get nodes
            print_color("Getting nodes...", Colors.BLUE)
            run_command(["ssh", "-o", "StrictHostKeyChecking=no", f"root@{vm_ip}",
                        "kubectl get nodes"], check=False)
            
            # Create a test pod
            test_pod_yaml = """
apiVersion: v1
kind: Pod
metadata:
  name: nginx
spec:
  containers:
  - name: nginx
    image: nginx:latest
    ports:
    - containerPort: 80
"""
            
            with tempfile.NamedTemporaryFile(mode='w', delete=False) as pod_file:
                pod_file.write(test_pod_yaml)
                pod_path = pod_file.name
            
            run_command(["scp", "-o", "StrictHostKeyChecking=no",
                        pod_path, f"root@{vm_ip}:/tmp/test-pod.yaml"])
            
            print_color("Creating test pod...", Colors.BLUE)
            run_command(["ssh", "-o", "StrictHostKeyChecking=no", f"root@{vm_ip}",
                        "kubectl apply -f /tmp/test-pod.yaml"], check=False)
            
            # Wait for pod to be running
            print_color("Waiting for pod to start (this may take a while)...", Colors.BLUE)
            time.sleep(30)
            
            # Check pod status
            run_command(["ssh", "-o", "StrictHostKeyChecking=no", f"root@{vm_ip}",
                        "kubectl get pods"], check=False)
            
            os.unlink(pod_path)
            return True
        else:
            print_color("API server is not healthy. Checking logs...", Colors.YELLOW)
            run_command(["ssh", "-o", "StrictHostKeyChecking=no", f"root@{vm_ip}",
                        "journalctl -u kube-apiserver -n 50"], check=False)
            return False
    except Exception as e:
        logger.error(f"Failed to test Kubernetes cluster: {e}")
        return False

def cleanup_network(tap_device: str) -> None:
    """Clean up network resources"""
    try:
        print_color("Cleaning up network resources...", Colors.YELLOW)
        
        # Check if tap device exists
        _, stdout, _ = run_command(["ip", "link", "show", tap_device], check=False)
        if tap_device in stdout:
            # Remove tap from bridge if it's part of one
            _, stdout, _ = run_command(["brctl", "show"], check=False)
            for line in stdout.splitlines():
                if tap_device in line:
                    bridge_name = line.split()[0]
                    if bridge_name:
                        print_color(f"Removing {tap_device} from bridge {bridge_name}", Colors.YELLOW)
                        run_command(["brctl", "delif", bridge_name, tap_device], check=False)
                    break
            
            # Set tap down
            print_color(f"Setting {tap_device} down", Colors.YELLOW)
            run_command(["ip", "link", "set", "dev", tap_device, "down"], check=False)
            
            # Delete tap device
            print_color(f"Deleting {tap_device}", Colors.YELLOW)
            run_command(["ip", "tuntap", "del", "dev", tap_device, "mode", "tap"], check=False)
        
        # Check if br0 exists and remove it
        _, stdout, _ = run_command(["ip", "link", "show", "br0"], check=False)
        if "br0" in stdout:
            print_color("Setting br0 down", Colors.YELLOW)
            run_command(["ip", "link", "set", "dev", "br0", "down"], check=False)
            print_color("Deleting br0", Colors.YELLOW)
            run_command(["brctl", "delbr", "br0"], check=False)
        
        # Clean up iptables rules
        print_color("Cleaning up iptables rules", Colors.YELLOW)
        # Get default interface
        _, stdout, _ = run_command(["ip", "route", "get", "8.8.8.8"], check=False)
        default_iface = None
        for word in stdout.split():
            if word.startswith("dev"):
                default_iface = stdout.split()[stdout.split().index(word) + 1]
                break
        
        if default_iface:
            run_command(["iptables", "-t", "nat", "-D", "POSTROUTING", "-o", default_iface, "-j", "MASQUERADE"], check=False)
            run_command(["iptables", "-D", "FORWARD", "-i", default_iface, "-o", "br0", "-m", "state", "--state", "RELATED,ESTABLISHED", "-j", "ACCEPT"], check=False)
            run_command(["iptables", "-D", "FORWARD", "-i", "br0", "-o", default_iface, "-j", "ACCEPT"], check=False)
    except Exception as e:
        logger.error(f"Error cleaning up network: {e}")

def cleanup(socket_path: str, firecracker_process: Optional[subprocess.Popen] = None, tap_device: str = DEFAULT_TAP_DEVICE) -> None:
    """Clean up resources"""
    if firecracker_process:
        firecracker_process.terminate()
        try:
            firecracker_process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            firecracker_process.kill()
    
    if os.path.exists(socket_path):
        os.unlink(socket_path)
    
    # Clean up network
    cleanup_network(tap_device)

def parse_args():
    """Parse command line arguments"""
    parser = argparse.ArgumentParser(
        description="Set up a Firecracker VM and install Kubernetes packages for testing"
    )
    parser.add_argument(
        "--output-dir", 
        default=DEFAULT_OUTPUT_DIR,
        help=f"Directory containing Kubernetes packages (default: {DEFAULT_OUTPUT_DIR})"
    )
    parser.add_argument(
        "--kernel", 
        default=DEFAULT_KERNEL_PATH,
        help=f"Path to kernel image (default: {DEFAULT_KERNEL_PATH})"
    )
    parser.add_argument(
        "--rootfs", 
        default=DEFAULT_ROOTFS_PATH,
        help=f"Path to rootfs image (default: {DEFAULT_ROOTFS_PATH})"
    )
    parser.add_argument(
        "--socket", 
        default=DEFAULT_SOCKET_PATH,
        help=f"Path to Firecracker socket (default: {DEFAULT_SOCKET_PATH})"
    )
    parser.add_argument(
        "--tap-device", 
        default=DEFAULT_TAP_DEVICE,
        help=f"Name of tap device (default: {DEFAULT_TAP_DEVICE})"
    )
    parser.add_argument(
        "--vm-ip", 
        default=DEFAULT_VM_IP,
        help=f"IP address for the VM (default: {DEFAULT_VM_IP})"
    )
    parser.add_argument(
        "--host-ip", 
        default=DEFAULT_HOST_IP,
        help=f"IP address for the host (default: {DEFAULT_HOST_IP})"
    )
    parser.add_argument(
        "--vcpu-count", 
        type=int,
        default=2,
        help="Number of vCPUs to allocate to the VM (default: 2)"
    )
    parser.add_argument(
        "--mem-size-mib", 
        type=int,
        default=2048,
        help="Amount of memory to allocate to the VM in MiB (default: 2048)"
    )
    
    return parser.parse_args()

def download_kernel_and_rootfs(kernel_path: str, rootfs_path: str) -> bool:
    """Download kernel and rootfs if they don't exist"""
    try:
        # Create directories if they don't exist
        kernel_dir = os.path.dirname(kernel_path)
        rootfs_dir = os.path.dirname(rootfs_path)
        
        os.makedirs(kernel_dir, exist_ok=True)
        os.makedirs(rootfs_dir, exist_ok=True)
        
        # Download kernel if it doesn't exist
        if not os.path.isfile(kernel_path):
            print_color(f"Downloading kernel image to {kernel_path}...", Colors.YELLOW)
            # Using a more recent kernel that has better network support
            kernel_url = "https://github.com/firecracker-microvm/firecracker/releases/download/v1.4.0/vmlinux-5.10.186"
            run_command(["wget", "-O", kernel_path, kernel_url])
        
        # Download rootfs if it doesn't exist
        if not os.path.isfile(rootfs_path):
            print_color(f"Downloading rootfs image to {rootfs_path}...", Colors.YELLOW)
            # Using a more recent rootfs that has better network support
            rootfs_url = "https://github.com/firecracker-microvm/firecracker/releases/download/v1.4.0/ubuntu-22.04.ext4"
            run_command(["wget", "-O", rootfs_path, rootfs_url])
        
        return True
    except Exception as e:
        logger.error(f"Failed to download kernel or rootfs: {e}")
        return False

def create_test_output_dir(output_dir: str) -> bool:
    """Create a test output directory with sample .deb files"""
    try:
        # Create output directory if it doesn't exist
        os.makedirs(output_dir, exist_ok=True)
        
        # Create sample .deb files for testing
        print_color(f"Creating sample .deb files in {output_dir}...", Colors.YELLOW)
        
        # List of sample package names
        packages = [
            "etcd_3.5.9_amd64.deb",
            "etcdctl_3.5.9_amd64.deb",
            "kube-apiserver_1.32.2_amd64.deb",
            "kube-controller-manager_1.32.2_amd64.deb",
            "kube-scheduler_1.32.2_amd64.deb",
            "kubectl_1.32.2_amd64.deb",
            "kubelet_1.32.2_amd64.deb",
            "kube-proxy_1.32.2_amd64.deb",
            "kubernetes-ca-certs_1.0.0_amd64.deb",
            "kubernetes-service-account-certs_1.0.0_amd64.deb",
            "kubernetes-apiserver-certs_1.0.0_amd64.deb",
            "kubernetes-controller-manager-certs_1.0.0_amd64.deb",
            "kubernetes-scheduler-certs_1.0.0_amd64.deb",
            "kubernetes-node-0-certs_1.0.0_amd64.deb",
            "kubernetes-proxy-certs_1.0.0_amd64.deb"
        ]
        
        # Create empty files for each package
        for package in packages:
            package_path = os.path.join(output_dir, package)
            with open(package_path, 'w') as f:
                f.write("This is a sample .deb file for testing purposes.\n")
        
        return True
    except Exception as e:
        logger.error(f"Failed to create test output directory: {e}")
        return False

def main():
    """Main function"""
    args = parse_args()
    
    print_color("Kubernetes Firecracker Test Environment", Colors.HEADER)
    print_color("======================================", Colors.HEADER)
    
    # Check dependencies
    print_color("Checking dependencies...", Colors.BLUE)
    if not check_dependencies():
        return 1
    
    # Find Firecracker path
    global DEFAULT_FIRECRACKER_PATH
    DEFAULT_FIRECRACKER_PATH = find_firecracker_path()
    print_color(f"Using Firecracker at: {DEFAULT_FIRECRACKER_PATH}", Colors.BLUE)
    
    # Verify Firecracker exists
    if not os.path.isfile(DEFAULT_FIRECRACKER_PATH):
        print_color(f"Firecracker not found at {DEFAULT_FIRECRACKER_PATH}", Colors.RED)
        print_color("Please install Firecracker or specify the correct path", Colors.RED)
        return 1
    
    # Download kernel and rootfs if they don't exist
    print_color("Checking kernel and rootfs...", Colors.BLUE)
    if not download_kernel_and_rootfs(args.kernel, args.rootfs):
        print_color("Failed to download kernel or rootfs", Colors.RED)
        return 1
    
    # Check if output directory exists, create test directory if it doesn't
    if not os.path.isdir(args.output_dir):
        print_color(f"Output directory {args.output_dir} does not exist", Colors.YELLOW)
        print_color("Creating test output directory...", Colors.BLUE)
        if not create_test_output_dir(args.output_dir):
            print_color("Failed to create test output directory", Colors.RED)
            return 1
    
    firecracker_process = None
    try:
        # Set up network
        print_color("Setting up network...", Colors.BLUE)
        if not setup_network(args.tap_device, args.host_ip):
            print_color("Failed to set up network", Colors.RED)
            return 1
        
        # Create Firecracker configuration
        print_color("Creating Firecracker configuration...", Colors.BLUE)
        config = create_firecracker_config(
            args.kernel,
            args.rootfs,
            args.socket,
            args.tap_device,
            args.vm_ip,
            args.host_ip,
            args.vcpu_count,
            args.mem_size_mib
        )
        
        # Start Firecracker VM
        print_color("Starting Firecracker VM...", Colors.BLUE)
        firecracker_process = start_firecracker_vm(config, args.socket)
        
        # Wait for VM to boot
        print_color("Waiting for VM to boot...", Colors.BLUE)
        time.sleep(10)
        
        # Display Firecracker logs for debugging
        if os.path.exists("/tmp/firecracker.log"):
            print_color("Firecracker logs:", Colors.BLUE)
            with open("/tmp/firecracker.log", "r") as f:
                log_content = f.read()
                print(log_content)
        
        # Check VM console output
        print_color("VM console output:", Colors.BLUE)
        if firecracker_process and firecracker_process.stdout:
            stdout_data, _ = firecracker_process.communicate(timeout=0.1)
            if stdout_data:
                print(stdout_data)
        
        # Wait a bit more for network to initialize
        time.sleep(20)
        
        # Check network status
        print_color("Network status:", Colors.BLUE)
        run_command(["ip", "addr", "show", "br0"], check=False)
        run_command(["ip", "addr", "show", args.tap_device], check=False)
        run_command(["brctl", "show"], check=False)
        
        # Check if VM is reachable
        print_color("Checking if VM is reachable...", Colors.BLUE)
        max_retries = 15
        retry_count = 0
        vm_reachable = False
        
        while retry_count < max_retries and not vm_reachable:
            try:
                _, stdout, _ = run_command(["ping", "-c", "1", "-W", "2", args.vm_ip], check=False)
                if "1 received" in stdout:
                    vm_reachable = True
                    print_color(f"VM is reachable at {args.vm_ip}", Colors.GREEN)
                else:
                    retry_count += 1
                    print_color(f"VM not reachable yet, retrying ({retry_count}/{max_retries})...", Colors.YELLOW)
                    
                    # Try to fix network if we're halfway through retries
                    if retry_count == max_retries // 2:
                        print_color("Attempting to fix network...", Colors.YELLOW)
                        # Restart network in VM (this might not work if SSH isn't available yet)
                        try:
                            run_command(["ssh", "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=5",
                                        f"root@{args.vm_ip}", "ifconfig eth0 down && ifconfig eth0 up"], check=False)
                        except:
                            pass
                    
                    time.sleep(5)
            except Exception as e:
                retry_count += 1
                print_color(f"Error checking VM reachability: {e}", Colors.YELLOW)
                time.sleep(5)
        
        if not vm_reachable:
            print_color(f"VM is not reachable after {max_retries} attempts", Colors.RED)
            print_color("Debugging information:", Colors.RED)
            
            # Check if firecracker is still running
            if firecracker_process.poll() is None:
                print_color("Firecracker process is still running", Colors.YELLOW)
            else:
                print_color(f"Firecracker process exited with code {firecracker_process.returncode}", Colors.RED)
                if firecracker_process.stderr:
                    stderr_data = firecracker_process.stderr.read()
                    if stderr_data:
                        print_color("Firecracker stderr:", Colors.RED)
                        print(stderr_data)
            
            # Try to get more network debugging info
            print_color("Network routing table:", Colors.YELLOW)
            run_command(["ip", "route"], check=False)
            
            print_color("Firewall rules:", Colors.YELLOW)
            run_command(["iptables", "-L", "-n"], check=False)
            run_command(["iptables", "-t", "nat", "-L", "-n"], check=False)
            
            return 1
        
        # Copy packages to VM
        print_color("Copying Kubernetes packages to VM...", Colors.BLUE)
        if not copy_packages_to_vm(args.output_dir, args.vm_ip):
            print_color("Failed to copy packages to VM", Colors.RED)
            return 1
        
        # Install packages in VM
        print_color("Installing Kubernetes packages in VM...", Colors.BLUE)
        if not install_packages_in_vm(args.vm_ip):
            print_color("Failed to install packages in VM", Colors.RED)
            return 1
        
        # Configure Kubernetes in VM
        print_color("Configuring Kubernetes in VM...", Colors.BLUE)
        if not configure_kubernetes_in_vm(args.vm_ip):
            print_color("Failed to configure Kubernetes in VM", Colors.RED)
            return 1
        
        # Test Kubernetes cluster
        print_color("Testing Kubernetes cluster...", Colors.BLUE)
        if not test_kubernetes_cluster(args.vm_ip):
            print_color("Failed to test Kubernetes cluster", Colors.RED)
            return 1
        
        print_color("Kubernetes cluster is up and running!", Colors.GREEN)
        print_color(f"You can access the VM using: ssh root@{args.vm_ip}", Colors.GREEN)
        print_color("Press Ctrl+C to stop the VM and clean up", Colors.YELLOW)
        
        # Keep the VM running until user interrupts
        while True:
            time.sleep(1)
    
    except KeyboardInterrupt:
        print_color("\nStopping VM and cleaning up...", Colors.YELLOW)
    except Exception as e:
        print_color(f"An error occurred: {e}", Colors.RED)
        return 1
    finally:
        cleanup(args.socket, firecracker_process, args.tap_device)
    
    print_color("Done!", Colors.GREEN)
    return 0

if __name__ == "__main__":
    sys.exit(main())
