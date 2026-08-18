# Makefile for libvirt network management
# Uses existing XML files: lab-wan.xml, lab-lan.xml, lab-dmz.xml, lab-mgmt.xml

SHELL := /bin/bash
CONNECT := --connect qemu:///system

# Network list
NETWORKS := lab-wan lab-lan lab-dmz lab-mgmt

# XML directory (current directory since files are here)
XML_DIR := .

.PHONY: help create-networks delete-networks list-networks start-networks stop-networks \
        restart-networks clean status define-only undefine-only

help:
	@echo "Available targets:"
	@echo "  make create-networks  - Define, start, and autostart all networks"
	@echo "  make delete-networks  - Destroy and undefine all networks"
	@echo "  make list-networks    - List all networks with status"
	@echo "  make start-networks   - Start all defined networks"
	@echo "  make stop-networks    - Stop (destroy) all networks"
	@echo "  make restart-networks - Restart all networks"
	@echo "  make status           - Show detailed network status (bridges, IPs)"
	@echo "  make define-only      - Only define networks (don't start)"
	@echo "  make undefine-only    - Only undefine networks (don't destroy)"
	@echo "  make clean            - Remove inactive/undefined network definitions"

# Create all networks (define, start, autostart)
create-networks: $(addprefix create-network-,$(NETWORKS))
	@echo ""
	@echo "✅ All networks created and started"
	@echo ""
	@echo "Network configuration:"
	@echo "  lab-wan:   10.0.0.1/30   (NAT enabled)"
	@echo "  lab-lan:   10.0.1.254/24 (isolated, no DHCP)"
	@echo "  lab-dmz:   10.0.2.254/24 (isolated)"
	@echo "  lab-mgmt:  10.0.3.254/24 (isolated)"

create-network-%:
	@echo "Creating network: $*"
	@if [ -f "$(XML_DIR)/$*.xml" ]; then \
		virsh $(CONNECT) net-define $(XML_DIR)/$*.xml 2>/dev/null && \
		echo "  ✅ $* defined" || \
		echo "  ⚠️  $* already defined or error"; \
		virsh $(CONNECT) net-start $* 2>/dev/null && \
		echo "  ✅ $* started" || \
		echo "  ⚠️  $* already running"; \
		virsh $(CONNECT) net-autostart $* 2>/dev/null && \
		echo "  ✅ $* autostart enabled" || \
		echo "  ⚠️  $* autostart already set"; \
	else \
		echo "  ❌ Error: $(XML_DIR)/$*.xml not found"; \
		exit 1; \
	fi

# Delete all networks (destroy and undefine)
delete-networks: $(addprefix delete-network-,$(NETWORKS))
	@echo "🗑️  All networks deleted"

delete-network-%:
	@echo "Deleting network: $*"
	@virsh $(CONNECT) net-destroy $* 2>/dev/null && echo "  ✅ $* stopped" || echo "  ⚠️  $* not running"
	@virsh $(CONNECT) net-undefine $* 2>/dev/null && echo "  ✅ $* undefined" || echo "  ⚠️  $* not defined"

# List all networks
list-networks:
	@echo "=== Libvirt Networks ==="
	@virsh $(CONNECT) net-list --all

# Start all networks
start-networks: $(addprefix start-network-,$(NETWORKS))

start-network-%:
	@echo "Starting network: $*"
	@virsh $(CONNECT) net-start $* 2>/dev/null && echo "  ✅ $* started" || echo "  ⚠️  $* already running or error"

# Stop all networks
stop-networks: $(addprefix stop-network-,$(NETWORKS))

stop-network-%:
	@echo "Stopping network: $*"
	@virsh $(CONNECT) net-destroy $* 2>/dev/null && echo "  ✅ $* stopped" || echo "  ⚠️  $* already stopped or error"

# Restart all networks
restart-networks: stop-networks start-networks
	@echo "🔄 All networks restarted"

# Define only (without starting)
define-only: $(addprefix define-,$(NETWORKS))

define-%:
	@echo "Defining network: $*"
	@if [ -f "$(XML_DIR)/$*.xml" ]; then \
		virsh $(CONNECT) net-define $(XML_DIR)/$*.xml && echo "  ✅ $* defined"; \
	else \
		echo "  ❌ Error: $(XML_DIR)/$*.xml not found"; \
		exit 1; \
	fi

# Undefine only (without destroying)
undefine-only: $(addprefix undefine-,$(NETWORKS))

undefine-%:
	@echo "Undefining network: $*"
	@virsh $(CONNECT) net-undefine $* 2>/dev/null && echo "  ✅ $* undefined" || echo "  ⚠️  $* not defined"

# Show detailed status
status:
	@echo "========================================="
	@echo "     NETWORK STATUS"
	@echo "========================================="
	@echo ""
	@echo "--- Libvirt Networks ---"
	@virsh $(CONNECT) net-list --all
	@echo ""
	@echo "--- Bridge Interfaces ---"
	@brctl show 2>/dev/null || ip link show | grep -E "virbr" | sed 's/^/  /'
	@echo ""
	@echo "--- Bridge IP Assignments ---"
	@for net in $(NETWORKS); do \
		bridge=$$(virsh $(CONNECT) net-dumpxml $$net 2>/dev/null | grep -oP "name='\K[^']+" | head -1); \
		ip=$$(virsh $(CONNECT) net-dumpxml $$net 2>/dev/null | grep -oP "address='\K[^']+" | head -1); \
		netmask=$$(virsh $(CONNECT) net-dumpxml $$net 2>/dev/null | grep -oP "netmask='\K[^']+" | head -1); \
		if [ -n "$$bridge" ] && [ -n "$$ip" ]; then \
			echo "  $$net: $$bridge = $$ip/$$netmask"; \
		elif [ -n "$$bridge" ]; then \
			echo "  $$net: $$bridge (no IP configured)"; \
		else \
			echo "  $$net: not defined"; \
		fi; \
	done
	@echo ""
	@echo "--- Active Bridge IPs (from host) ---"
	@ip -4 addr show | grep -E "virbr" | grep inet | sed 's/^/  /' || echo "  No bridges active"
	@echo ""
	@echo "========================================="

# Clean up (remove inactive networks)
clean:
	@echo "Cleaning up inactive networks..."
	@for net in $$(virsh $(CONNECT) net-list --inactive --name 2>/dev/null); do \
		echo "  Removing inactive: $$net"; \
		virsh $(CONNECT) net-undefine $$net; \
	done
	@echo "✅ Cleanup complete"

# Verify network configuration matches expected
verify:
	@echo "Verifying network configuration..."
	@echo ""
	@errors=0; \
	for net in $(NETWORKS); do \
		echo "Checking $$net..."; \
		if ! virsh $(CONNECT) net-list --all | grep -q "$$net.*active"; then \
			echo "  ❌ $$net is not active"; \
			errors=$$((errors + 1)); \
		else \
			ip=$$(virsh $(CONNECT) net-dumpxml $$net 2>/dev/null | grep -oP "address='\K[^']+" | head -1); \
			case $$net in \
				lab-wan) expected="10.0.0.1" ;; \
				lab-lan) expected="10.0.1.254" ;; \
				lab-dmz) expected="10.0.2.254" ;; \
				lab-mgmt) expected="10.0.3.254" ;; \
			esac; \
			if [ "$$ip" = "$$expected" ]; then \
				echo "  ✅ $$net has correct IP: $$ip"; \
			else \
				echo "  ❌ $$net has IP $$ip, expected $$expected"; \
				errors=$$((errors + 1)); \
			fi; \
		fi; \
	done; \
	echo ""; \
	if [ $$errors -eq 0 ]; then \
		echo "✅ All networks verified successfully"; \
	else \
		echo "❌ $$errors network(s) have issues"; \
		exit 1; \
	fi

# Recreate networks (delete then create)
recreate-networks: delete-networks create-networks
	@echo "🔄 Networks recreated"

# Default target
all: help
