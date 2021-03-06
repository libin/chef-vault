require 'chef/knife'

class EncryptCert < Chef::Knife
  deps do
    require 'chef/search/query'
    require 'chef/shef/ext'
  end

  banner "knife encrypt cert --search SEARCH --cert CERT --password PASSWORD --name NAME --admins ADMINS"

  option :search,
    :short => '-S SEARCH',
    :long => '--search SEARCH',
    :description => 'node search for nodes to encrypt to' 

  option :cert,
    :short => '-C CERT',
    :long => '--cert CERT',
    :description => 'cert with contents to encrypt'

  option :admins,
    :short => '-A ADMINS',
    :long => '--admins ADMINS',
    :description => 'administrators who can decrypt certificate'

  option :password,
    :short => '-P PASSWORD',
    :long => '--password PASSWORD',
    :description => 'optional pfx password' 

  option :name,
    :short => '-N NAME',
    :long => '--name NAME',
    :description => 'optional data bag name' 

  def run
    unless config[:search]
      puts("You must supply either -S or --search")
      exit 1
    end
    unless config[:cert]
      puts("You must supply either -C or --cert")
      exit 1
    end
    unless config[:admins]
      puts("You must supply either -A or --admins")
      exit 1
    end
    Shef::Extensions.extend_context_object(self)

    data_bag = "certs"
    data_bag_path = "./data_bags/#{data_bag}"

    node_search = config[:search]
    admins = config[:admins]
    file_to_encrypt = config[:cert]
    contents = open(file_to_encrypt, "rb").read
    name = config[:name] ? config[:name].gsub(".", "_") : File.basename(file_to_encrypt, ".*").gsub(".", "_")
    
    current_dbi = Hash.new
    current_dbi_keys = Hash.new
    if File.exists?("#{data_bag_path}/#{name}_keys.json") && File.exists?("#{data_bag_path}/#{name}.json")
      current_dbi_keys = JSON.parse(open("#{data_bag_path}/#{name}_keys.json").read())
      current_dbi = JSON.parse(open("#{data_bag_path}/#{name}.json").read())

      unless equal?(data_bag, name, "contents", contents)
        puts("FATAL: Content in #{data_bag_path}/#{name}.json does not match content in file supplied!")
        exit 1
      end
    else
      puts("INFO: Existing data bag #{data_bag}/#{name} does not exist in #{data_bag_path}, continuing as fresh build...")
    end

    # Get the public keys for all of the nodes to encrypt for.  Skipping the nodes that are already in
    # the data bag
    keyfob = Hash.new
    public_keys = search(:node, node_search).map(&:name).map do |client|
      begin
        if current_dbi_keys[client]
          puts("INFO: Skipping #{client} as it is already in the data bag...")
        else
          puts("INFO: Adding #{client} to public_key array...")
          cert_der = api.get("clients/#{client}")['certificate']
          cert = OpenSSL::X509::Certificate.new cert_der
          keyfob[client]=OpenSSL::PKey::RSA.new cert.public_key
        end
      rescue Exception => node_error
        puts("WARNING: Caught exception: #{node_error.message} while processing #{client}, so skipping...")
      end
    end
    
    # Get the public keys for the admin users, skipping users already in the data bag
    public_keys << admins.split(",").map do |user|
      begin
        if current_dbi_keys[user]
          puts("INFO: Skipping #{user} as it is already in the data bag")
        else
          puts("INFO: Adding #{user} to public_key array...")
          public_key = api.get("users/#{user}")['public_key']
          keyfob[user] = OpenSSL::PKey::RSA.new public_key
        end
      rescue Exception => user_error
        puts("WARNING: Caught exception: #{user_error.message} while processing #{user}, so skipping...")
      end
    end

    if public_keys.length == 0
      puts "A node search for #{node_search} returned no results" 
      exit 1
    end

    # Get the current secret, is nil if current secret does not exist yet
    current_secret = get_shared_secret(data_bag, name)
    data_bag_shared_key = current_secret ? current_secret : OpenSSL::PKey::RSA.new(245).to_pem.lines.to_a[1..-2].join
    enc_db_key_dbi = current_dbi_keys.empty? ? Mash.new({id: "#{name}_keys"}) : current_dbi_keys

    # Encrypt for every new node not already in the data bag
    keyfob.each do |node,pkey|
      puts("INFO: Encrypting for #{node}...")
      enc_db_key_dbi[node] = Base64.encode64(pkey.public_encrypt(data_bag_shared_key))
    end unless keyfob.empty?

    # Delete existing keys data bag and rewrite the whole bag from memory
    puts("INFO: Writing #{data_bag_path}/#{name}_keys.json...")
    File.delete("#{data_bag_path}/#{name}_keys.json") if File.exists?("#{data_bag_path}/#{name}_keys.json")
    File.open("#{data_bag_path}/#{name}_keys.json",'w').write(JSON.pretty_generate(enc_db_key_dbi))

    # If the existing certificate bag does not exist, write it out with the correct certificate
    # Otherwise leave the existing bag alone
    if current_dbi.empty?
      dbi_mash = Mash.new({id: name, contents: contents})
      dbi_mash.merge!({password: config[:password]}) if config[:password]
      dbi = Chef::DataBagItem.from_hash(dbi_mash)
      edbi = Chef::EncryptedDataBagItem.encrypt_data_bag_item(dbi, data_bag_shared_key)

      puts("INFO: Writing #{data_bag_path}/#{name}.json...")
      open("#{data_bag_path}/#{name}.json",'w').write(JSON.pretty_generate(edbi))
    end

    puts("INFO: Successfully wrote #{data_bag_path}/#{name}.json & #{data_bag_path}/#{name}_keys.json!")
  end

  def equal?(db, dbi, key, value)
    data_bag_path = "./data_bags/#{db}"

    shared_secret = get_shared_secret(db, dbi)
    dbi = JSON.parse(open("#{data_bag_path}/#{dbi}.json").read())
    dbi = Chef::EncryptedDataBagItem.new dbi, shared_secret

    dbi[key] == value
  end

  def get_shared_secret(db, dbi)
    data_bag_path = "./data_bags/#{db}"

    private_key = OpenSSL::PKey::RSA.new(open(Chef::Config[:client_key]).read())
    key = File.exists?("#{data_bag_path}/#{dbi}_keys.json") ? JSON.parse(open("#{data_bag_path}/#{dbi}_keys.json").read()) : nil
    
    begin      
      private_key.private_decrypt(Base64.decode64(key[Chef::Config[:node_name]]))
    rescue
      nil
    end
  end
end
