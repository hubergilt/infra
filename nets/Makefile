# Makefile for libvirt network management
# Networks per general-nw.puml — 8 segments for fw01.ad.lab

SHELL   := /bin/bash
CONNECT := --connect qemu:///system

NETWORKS := lab-wan lab-app lab-dmz-web lab-mgmt lab-clients lab-dmz-vpn lab-data lab-identity

XML_DIR := .

.PHONY: help create-networks delete-networks list-networks start-networks stop-networks \
        restart-networks clean status define-only undefine-only verify recreate-networks info

help:
	@echo "Available targets:"
	@echo "  make create-networks  - Define, start, and autostart all networks"
	@echo "  make delete-networks  - Destroy and undefine all networks"
	@echo "  make list-networks    - List all networks with status"
	@echo "  make start-networks   - Start all defined networks"
	@echo "  make stop-networks    - Stop (destroy) all networks"
	@echo "  make restart-networks - Restart all networks"
	@echo "  make status           - Show detailed network status (bridges, IPs)"
	@echo "  make verify           - Verify IPs match expected topology"
	@echo "  make info             - Full segment details: CIDR, gateway, broadcast, DHCP, DNS, hosts"
	@echo "  make clean            - Remove inactive/undefined network definitions"
	@echo ""
	@echo "Network layout:"
	@echo "  lab-wan:      10.0.0.1/30    (NAT — WAN p2p to fw01)"
	@echo "  lab-app:      10.0.1.254/24  (isolated — app/gw/dhcp/fs/ca tier)"
	@echo "  lab-dmz-web:  10.0.2.254/24  (isolated — waf01/web01/lb01/rodc01)"
	@echo "  lab-mgmt:     10.0.3.254/24  (isolated — jump01/siem01/sccm01/backup01)"
	@echo "  lab-clients:  10.0.4.254/24  (isolated — workstations, DHCP via relay)"
	@echo "  lab-dmz-vpn:  10.0.5.254/24  (isolated — vpn01/rodc01 VPN leg)"
	@echo "  lab-data:     10.0.6.254/24  (isolated — sql01/ora01/fs01/fs02)"
	@echo "  lab-identity: 10.0.7.254/24  (isolated — ad01/ad02/ca01/ca02)"

create-networks: $(addprefix create-network-,$(NETWORKS))
	@echo ""
	@echo "✅ All networks created and started"
	@$(MAKE) status

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

delete-networks: $(addprefix delete-network-,$(NETWORKS))
	@echo "🗑️  All networks deleted"

delete-network-%:
	@echo "Deleting network: $*"
	@virsh $(CONNECT) net-destroy $* 2>/dev/null && echo "  ✅ $* stopped" || echo "  ⚠️  $* not running"
	@virsh $(CONNECT) net-undefine $* 2>/dev/null && echo "  ✅ $* undefined" || echo "  ⚠️  $* not defined"

list-networks:
	@echo "=== Libvirt Networks ==="
	@virsh $(CONNECT) net-list --all

start-networks: $(addprefix start-network-,$(NETWORKS))

start-network-%:
	@virsh $(CONNECT) net-start $* 2>/dev/null && echo "  ✅ $* started" || echo "  ⚠️  $* already running"

stop-networks: $(addprefix stop-network-,$(NETWORKS))

stop-network-%:
	@virsh $(CONNECT) net-destroy $* 2>/dev/null && echo "  ✅ $* stopped" || echo "  ⚠️  $* already stopped"

restart-networks: stop-networks start-networks
	@echo "🔄 All networks restarted"

define-only: $(addprefix define-,$(NETWORKS))

define-%:
	@if [ -f "$(XML_DIR)/$*.xml" ]; then \
		virsh $(CONNECT) net-define $(XML_DIR)/$*.xml && echo "  ✅ $* defined"; \
	else \
		echo "  ❌ Error: $(XML_DIR)/$*.xml not found"; exit 1; \
	fi

undefine-only: $(addprefix undefine-,$(NETWORKS))

undefine-%:
	@virsh $(CONNECT) net-undefine $* 2>/dev/null && echo "  ✅ $* undefined" || echo "  ⚠️  $* not defined"

status:
	@echo "========================================="
	@echo "     NETWORK STATUS"
	@echo "========================================="
	@echo ""
	@echo "--- Libvirt Networks ---"
	@virsh $(CONNECT) net-list --all
	@echo ""
	@echo "--- Bridge IP Assignments ---"
	@for net in $(NETWORKS); do \
		bridge=$$(virsh $(CONNECT) net-dumpxml $$net 2>/dev/null | grep -oP "name='\K[^']+"); \
		ip=$$(virsh $(CONNECT) net-dumpxml $$net 2>/dev/null | grep -oP "<ip address='\K[^']+" | head -1); \
		if [ -n "$$bridge" ] && [ -n "$$ip" ]; then \
			echo "  $$net: $$bridge = $$ip"; \
		else \
			echo "  $$net: not defined"; \
		fi; \
	done
	@echo ""
	@echo "--- Active Bridge IPs (from host) ---"
	@ip -4 addr show | grep -E "virbr" | grep inet | sed 's/^/  /' || echo "  No bridges active"
	@echo "========================================="

verify:
	@echo "Verifying network configuration..."
	@echo ""
	@errors=0; \
	declare -A expected=( \
		[lab-wan]="10.0.0.1" \
		[lab-app]="10.0.1.254" \
		[lab-dmz-web]="10.0.2.254" \
		[lab-mgmt]="10.0.3.254" \
		[lab-clients]="10.0.4.254" \
		[lab-dmz-vpn]="10.0.5.254" \
		[lab-data]="10.0.6.254" \
		[lab-identity]="10.0.7.254" \
	); \
	for net in $(NETWORKS); do \
		if ! virsh $(CONNECT) net-list --all | grep -qE "^\s+$$net\s+active"; then \
			echo "  ❌ $$net not active"; errors=$$((errors+1)); \
		else \
			ip=$$(virsh $(CONNECT) net-dumpxml $$net 2>/dev/null | grep -oP "<ip address='\K[^']+" | head -1); \
			if [ "$$ip" = "$${expected[$$net]}" ]; then \
				echo "  ✅ $$net → $$ip"; \
			else \
				echo "  ❌ $$net has $$ip, expected $${expected[$$net]}"; \
				errors=$$((errors+1)); \
			fi; \
		fi; \
	done; \
	echo ""; \
	[ $$errors -eq 0 ] && echo "✅ All networks verified" || { echo "❌ $$errors issue(s) found"; exit 1; }

clean:
	@echo "Cleaning up inactive networks..."
	@for net in $$(virsh $(CONNECT) net-list --inactive --name 2>/dev/null); do \
		echo "  Removing inactive: $$net"; \
		virsh $(CONNECT) net-undefine $$net; \
	done
	@echo "✅ Cleanup complete"

recreate-networks: delete-networks create-networks

all: help

info:
	@echo ""
	@echo "  ad.lab — NETWORK SEGMENTS"
	@echo ""
	@printf "  %-3s %-14s %-16s %-16s %-15s %-9s %-4s %-22s\n" \
		"" "NETWORK" "CIDR" "GATEWAY" "BRIDGE" "MODE" "DNS" "DHCP RANGE"
	@echo "  ───────────────────────────────────────────────────────────────────────────────────────────────────"
	@for net in $(NETWORKS); do \
		xml=$$(virsh $(CONNECT) net-dumpxml $$net 2>/dev/null); \
		if [ -z "$$xml" ]; then \
			printf "  %-3s %-14s %-16s\n" "⚠️" "$$net" "not defined"; \
			continue; \
		fi; \
		bridge=$$(echo "$$xml"    | grep -oP "<bridge name='\K[^']+"  | head -1); \
		ip=$$(echo "$$xml"        | grep -oP "<ip address='\K[^']+"   | head -1); \
		mask=$$(echo "$$xml"      | grep -oP "netmask='\K[^']+"       | head -1); \
		fwd=$$(echo "$$xml"       | grep -oP "<forward mode='\K[^']+" | head -1); \
		dns=$$(echo "$$xml"       | grep -oP "<dns enable='\K[^']+"   | head -1); \
		dhcp_from=$$(echo "$$xml" | grep -oP "<range from='\K[^']+"   | head -1); \
		dhcp_to=$$(echo "$$xml"   | grep -oP "to='\K[^']+"            | head -1); \
		state=$$(virsh $(CONNECT) net-list --all | awk -v n="$$net" '$$1==n{print $$2}'); \
		\
		[ -z "$$fwd" ]     && fwd="isolated"; \
		[ -z "$$dns" ]     && dns="no"; \
		[ "$$dns" = "no" ] && dns_str="off" || dns_str="on"; \
		\
		prefix=$$(python3 -c "import ipaddress; print(ipaddress.IPv4Network('0.0.0.0/'+'$$mask').prefixlen)" 2>/dev/null || echo "?"); \
		cidr=$$(python3 -c "import ipaddress; print(ipaddress.IPv4Interface('$$ip/$$prefix').network)" 2>/dev/null || echo "$$ip/$$prefix"); \
		gw="$$ip/$$prefix"; \
		\
		if [ -n "$$dhcp_from" ] && [ -n "$$dhcp_to" ]; then \
			dhcp="$$dhcp_from–$$dhcp_to"; \
		else \
			dhcp="static only"; \
		fi; \
		\
		[ "$$state" = "active" ] && icon="🟢" || icon="🔴"; \
		\
		printf "  %-3s %-14s %-16s %-16s %-15s %-9s %-4s %-22s\n" \
			"$$icon" "$$net" "$$cidr" "$$gw" "$$bridge" "$$fwd" "$$dns_str" "$$dhcp"; \
	done
	@echo "  ───────────────────────────────────────────────────────────────────────────────────────────────────"
	@echo ""
