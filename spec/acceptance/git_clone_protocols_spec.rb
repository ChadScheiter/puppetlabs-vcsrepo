require 'spec_helper_acceptance'

hosts.each do |host|

  describe 'clones a repo with git' do
    tmpdir =  host.tmpdir('vcsrepo')

    before(:all) do
      # {{{ setup
      apply_manifest_on(host, "user{'testuser': ensure => present, managehome => true }")
      apply_manifest_on(host, "user{'vagrant': ensure => present, }")
      # install git
      install_package(host, 'git')
      install_package(host, 'git-daemon')
      # create ssh keys
      on(host, 'mkdir -p /home/testuser/.ssh')
      on(host, 'ssh-keygen -q -t rsa -f /root/.ssh/id_rsa -N ""')

      # copy public key to authorized_keys
      on(host, 'cat /root/.ssh/id_rsa.pub >> /home/testuser/.ssh/authorized_keys')
      on(host, 'echo -e "Host *\n\tStrictHostKeyChecking no\n" >> /home/testuser/.ssh/config')
      on(host, 'echo -e "Host *\n\tStrictHostKeyChecking no\n" >> /root/.ssh/config')
      on(host, 'chown -R testuser:testuser /home/testuser/.ssh')
      on(host, 'chown -R root:root /root/.ssh')

      # create git repo
      my_root = File.expand_path(File.join(File.dirname(__FILE__), '..'))
      scp_to(host, "#{my_root}/acceptance/files/create_git_repo.sh", tmpdir)
      on(host, "cd #{tmpdir} && ./create_git_repo.sh")

      # copy ssl keys
      scp_to(host, "#{my_root}/acceptance/files/server.crt", tmpdir)
      scp_to(host, "#{my_root}/acceptance/files/server.key", tmpdir)
      # }}}
    end

    after(:all) do
      # {{{ teardown
      apply_manifest_on(host, "user{'testuser': ensure => absent, managehome => true }")
      apply_manifest_on(host, "file{'/root/.ssh/id_rsa': ensure => absent, force => true }")
      apply_manifest_on(host, "file{'/root/.ssh/id_rsa.pub': ensure => absent, force => true }")
      # }}}
    end


    #---------------  TESTS ----------------------#

    context 'using local protocol (file URL)' do
      before(:all) do
        apply_manifest_on(host, "file {'#{tmpdir}/testrepo': ensure => directory, purge => true, recurse => true, recurselimit => 1, force => true; }")
      end

      it 'should have HEAD pointing to master' do
        pp = <<-EOS
        vcsrepo { "#{tmpdir}/testrepo":
          ensure => present,
          provider => git,
          source => "file://#{tmpdir}/testrepo.git",
        }
        EOS

        # Run it twice and test for idempotency
        apply_manifest_on(host, pp, :catch_failures => true)
        apply_manifest_on(host, pp, :catch_changes => true)
      end

      describe file("#{tmpdir}/testrepo/.git/HEAD") do
        it { should contain 'ref: refs/heads/master' }
      end

    end

    context 'using local protocol (file path)' do
      before(:all) do
        apply_manifest_on(host, "file {'#{tmpdir}/testrepo': ensure => directory, purge => true, recurse => true, recurselimit => 1, force => true; }")
      end

      it 'should have HEAD pointing to master' do
        pp = <<-EOS
        vcsrepo { "#{tmpdir}/testrepo":
          ensure => present,
          provider => git,
          source => "#{tmpdir}/testrepo.git",
        }
        EOS

        # Run it twice and test for idempotency
        apply_manifest_on(host, pp, :catch_failures => true)
        apply_manifest_on(host, pp, :catch_changes => true)
      end

      describe file("#{tmpdir}/testrepo/.git/HEAD") do
        it { should contain 'ref: refs/heads/master' }
      end

    end

    context 'using git protocol' do
      before(:all) do
        apply_manifest_on(host, "file {'#{tmpdir}/testrepo': ensure => directory, purge => true, recurse => true, recurselimit => 1, force => true; }")
        on(host, "nohup git daemon  --detach --base-path=/#{tmpdir}")
      end

      it 'should have HEAD pointing to master' do
        pp = <<-EOS
        vcsrepo { "#{tmpdir}/testrepo":
          ensure => present,
          provider => git,
          source => "git://#{host}/testrepo.git",
        }
        EOS

        # Run it twice and test for idempotency
        apply_manifest_on(host, pp, :catch_failures => true)
        apply_manifest_on(host, pp, :catch_changes => true)
      end
      describe file("#{tmpdir}/testrepo/.git/HEAD") do
        it { should contain 'ref: refs/heads/master' }
      end

      after(:all) do
        on(host, 'pkill -9 git')
      end
    end

    context 'using http protocol' do
      before(:all) do
        apply_manifest_on(host, "file {'#{tmpdir}/testrepo': ensure => directory, purge => true, recurse => true, recurselimit => 1, force => true; }")
        daemon =<<-EOF
        require 'webrick'
        server = WEBrick::HTTPServer.new(:Port => 8000, :DocumentRoot => "#{tmpdir}")
        WEBrick::Daemon.start
        server.start
        EOF
        create_remote_file(host, '/tmp/daemon.rb', daemon)
        on(host, "ruby /tmp/daemon.rb")
      end

      it 'should have HEAD pointing to master' do
        pp = <<-EOS
        vcsrepo { "#{tmpdir}/testrepo":
          ensure => present,
          provider => git,
          source => "http://#{host}:8000/testrepo.git",
        }
        EOS

        # Run it twice and test for idempotency
        apply_manifest_on(host, pp, :catch_failures => true)
        apply_manifest_on(host, pp, :catch_changes => true)
      end
      describe file("#{tmpdir}/testrepo/.git/HEAD") do
        it { should contain 'ref: refs/heads/master' }
      end

      after(:all) do
        on(host, 'pkill -9 ruby')
      end
    end

    context 'using https protocol' do
      before(:all) do
        apply_manifest_on(host, "file {'#{tmpdir}/testrepo': ensure => directory, purge => true, recurse => true, recurselimit => 1, force => true; }")
        daemon =<<-EOF
        require 'webrick'
        require 'webrick/https'
        server = WEBrick::HTTPServer.new(
        :Port               => 8443,
        :DocumentRoot       => "#{tmpdir}",
        :SSLEnable          => true,
        :SSLVerifyClient    => OpenSSL::SSL::VERIFY_NONE,
        :SSLCertificate     => OpenSSL::X509::Certificate.new(  File.open("#{tmpdir}/server.crt").read),
        :SSLPrivateKey      => OpenSSL::PKey::RSA.new(          File.open("#{tmpdir}/server.key").read),
        :SSLCertName        => [ [ "CN",WEBrick::Utils::getservername ] ])
        WEBrick::Daemon.start
        server.start
        EOF
        create_remote_file(host, '/tmp/daemon.rb', daemon)
        on(host, "ruby /tmp/daemon.rb")
      end

      it 'should have HEAD pointing to master' do
        # howto whitelist ssl cert
        pp = <<-EOS
        vcsrepo { "#{tmpdir}/testrepo":
          ensure => present,
          provider => git,
          source => "https://#{host}:8443/testrepo.git",
        }
        EOS

        # Run it twice and test for idempotency
        apply_manifest_on(host, pp, :catch_failures => true)
        apply_manifest_on(host, pp, :catch_changes => true)
      end

      describe file("#{tmpdir}/testrepo/.git/HEAD") do
        it { should contain 'ref: refs/heads/master' }
      end

      after(:all) do
        on(host, 'pkill -9 ruby')
      end
    end

    context 'using ssh protocol' do
      before(:all) do
        apply_manifest_on(host, "file {'#{tmpdir}/testrepo': ensure => directory, purge => true, recurse => true, recurselimit => 1, force => true; }")
      end
      it 'should have HEAD pointing to master' do
        pp = <<-EOS
        vcsrepo { "#{tmpdir}/testrepo":
          ensure => present,
          provider => git,
          source => "ssh://root@#{host}#{tmpdir}/testrepo.git",
        }
        EOS

        # Run it twice and test for idempotency
        apply_manifest_on(host, pp, :catch_failures => true)
        apply_manifest_on(host, pp, :catch_changes => true)
      end

      describe file("#{tmpdir}/testrepo/.git/HEAD") do
        it { should contain 'ref: refs/heads/master' }
      end
    end

  end
end