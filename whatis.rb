#!/usr/bin/ruby

require "ipaddr"
require "net/http"
require "optparse"
require "puppetdb"
require "resolv"
require "timeout"
require "xmlrpc/client"
require "yaml"

DOMAINS = [
	".rc.fas.harvard.edu", ".rc.domain",
]
COBBLER_HOST = "cobbler.rc.fas.harvard.edu"
PUPPETDB_HOST = "pdb01.rc.fas.harvard.edu"
RACKTABLES_HOST = "racktables.rc.fas.harvard.edu"

# Default list of facts to display.
DEFAULT_FACTS_TO_DISPLAY = [
	"hostname", "born_on", "notes", "owner", "group", "docs", "rt",
	"manufacturer", "productname", "serialnumber", "operatingsystem",
	"operatingsystemrelease", "processor0", "processorcount", "memorytotal",
	"kernelrelease", "ipaddress", "macaddress", "vlan", "location_row",
	"location_rack", "location_ru", "uptime", "virtual",
]

def get_facts(fqdn)
	client = PuppetDB::Client.new({:server => "http://#{PUPPETDB_HOST}:8080"})

	response = client.request("facts", [:"=", "certname", fqdn])
	if response.data.length == 0
		return nil
	end

	facts = {}
	response.data.each do |fact|
		facts[fact["name"]] = fact["value"]
	end
	return facts
end

def cname_check(host)
	r = Resolv::DNS.new

	begin
		cname_to = r.getresource(host, Resolv::DNS::Resource::IN::CNAME)
	rescue Resolv::ResolvError
		return nil
	end
	if cname_to.empty?
		return nil
	end

	return cname_to.name.to_s
end

def cobbler_direct(fqdn)
	connection = XMLRPC::Client.new2("https://#{COBBLER_HOST}/cobbler_api")
	system_data = connection.call("find_system_by_dns_name", fqdn)
	if system_data.empty?
		return {}
	end

	cobbler_info = {
		"hostname" => system_data["hostname"],
		"ipaddress" => system_data["ip_address_eth0"],
		"macaddress" => system_data["mac_address_eth0"],
	}

	comment = YAML::load(system_data["comment"])
	if comment
		cobbler_info = cobbler_info.merge({
			"owner" => comment["owner"],
			"group" => comment["group"],
			"rt" => comment["rt"],
			"docs" => comment["docs"],
			"notes" => comment["notes"],
		})
	end

	return cobbler_info
end

def racktables_direct(fqdn)
	begin
		Timeout::timeout(2) {
			hostname = fqdn.split(".")[0]
			uri = URI("https://#{RACKTABLES_HOST}/rackfacts/systems/#{hostname}")

			http = Net::HTTP.new(uri.host, uri.port)
			http.use_ssl = true
			response = http.get(uri.request_uri)
			if response.code.to_i != 200
				return {}
			end

			rackfacts = YAML::load(response.body)
			return {
				"location_ru" => rackfacts["ru"],
				"location_rack" => rackfacts["rack"],
				"location_row" => rackfacts["row"],
			}
		}
	rescue Timeout::Error
		return {}
	end
end

options = {}
OptionParser.new do |opts|
	# FIXME: better usage, check for mutually exclusive -j and -y
	opts.banner = "Usage: whatis [options] HOSTNAME"

	opts.on("-a", "--all", "Display all facts") do |a|
		options[:all] = a
	end
	opts.on("-j", "--json", "JSON output") do |j|
		options[:json] = j
	end
	opts.on("-y", "--yaml", "YAML output") do |y|
		options[:yaml] = y
	end
end.parse!

if ARGV.length != 1
	puts "Please pass a hostname, see --help"
	exit 1
end

# Translate IP addresses to their hostnames.
if !(IPAddr.new(ARGV[0]) rescue nil).nil?
	host = Resolv.new.getname(ARGV[0])
else
	host = ARGV[0]
end
host = host.downcase

fqdns = [host]
if not host.include?(".")
	DOMAINS.reverse.each do |domain|
		fqdns.unshift(host + domain)
	end
end
fqdns.each do |fqdn|
	$facts = get_facts(fqdn)
	if $facts
		break
	end
end

if not $facts
	cname_target = cname_check(host)
	if cname_target
		$facts = get_facts(cname_target)
	end

	if not $facts
		fqdns.each do |fqdn|
			$facts = cobbler_direct(fqdn)
			if $facts
				break
			end
		end
		$facts = $facts.merge(racktables_direct(host))
		if $facts.empty?
			puts "No information for this host in Puppet, Cobbler, or Racktables."
			exit 1
		end
	end
end

facts_to_display = DEFAULT_FACTS_TO_DISPLAY

if $facts["kvm_production"] == "true"
	facts_to_display.push("hypervisor", "vms", "kvm_vlans")
end
if $facts["virtual"] == "kvm"
	client = PuppetDB::Client.new({:server => "http://#{PUPPETDB_HOST}:8080"})

	response = client.request("nodes", [:"=", ["fact", "kvm_production"], "true"])
	response.data.each do |fact|
		hypervisor_facts = get_facts(fact["name"])
		if hypervisor_facts["kvm_vms"] == "NO_VMS"
			next
		end
		vms = eval(hypervisor_facts["kvm_vms"])
		if vms.include?($facts["hostname"])
			$facts["hypervisor"] = fact["name"]
			$facts["kvm_pool"] = hypervisor_facts["kvm_#{$facts['hostname']}_pool"]
			vnc_port = 5900 + hypervisor_facts["kvm_#{$facts['hostname']}_vnc"].to_i
			$facts["console"] = "vnc://#{fact["name"]}:#{vnc_port}"
		end
	end
	facts_to_display.push("hypervisor", "kvm_pool", "console")
end
if $facts["rcnfs_node"] == "true"
	facts_to_display.push("rcnfs_node", "hosted_filesystems")
end
if $facts["warranty_end"] != nil
	facts_to_display.push("warranty_end")
end

if options[:json]
	puts $facts.to_json
elsif options[:yaml]
	puts $facts.to_yaml
else
	if options[:all]
		facts_to_display = $facts.keys
	end
	facts_to_display.each do |val|
		if not $facts[val]
			next
		end
		puts "#{val}: #{$facts[val]}"
	end
end
