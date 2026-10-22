# frozen_string_literal: true

require "rails_helper"

# IMP-01a0f109 — manifest identity fields are concatenated by the on-node agent
# into /etc/passwd, /etc/group, /etc/shadow, /etc/gshadow and /etc/sudoers.d.
# A ':' or newline in any of them (or a reserved name / privileged group) would
# add a root-equivalent account or sudo rule on every node carrying the module.
# The platform must refuse such a manifest when it is AUTHORED, with an error
# that names the field, and must never persist it.
RSpec.describe System::ManifestImportService, type: :service do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:mod) do
    create(:system_node_module, account: account, node_platform: platform,
           category: category, variety: "subscription", name: "demo-mod")
  end

  before do
    ::System::ModuleUserDeclaration.delete_all
    ::System::ServiceUserGroupMembership.delete_all
    ::System::SudoersGrant.delete_all
    ::System::ServiceUser.delete_all
    ::System::ServiceGroup.delete_all
  end

  def yaml_for(extra)
    { "schema_version" => 1, "name" => "demo-mod", "services" => [] }.merge(extra).to_yaml
  end

  def user(overrides = {})
    { "name" => "svcdemo", "shell" => "/usr/sbin/nologin", "home" => "/var/lib/svcdemo",
      "gecos" => "Demo service, ops (x)" }.merge(overrides)
  end

  def grant(overrides = {})
    { "id" => "reload", "user" => "svcdemo", "runas" => "root",
      "commands" => [ "/usr/bin/systemctl reload demo.service" ] }.merge(overrides)
  end

  def errors_for(extra)
    described_class.validate_only(yaml: yaml_for(extra), node_module: mod).validation_errors.join("\n")
  end

  describe "user fields" do
    {
      "gecos newline injecting a uid-0 line" => [ { "gecos" => "x\ntoor:x:0:0::/root:/bin/bash" }, /users\[0\]\.gecos/ ],
      "gecos colon"                          => [ { "gecos" => "a:b" },                           /users\[0\]\.gecos.*':'/ ],
      "gecos carriage return"                => [ { "gecos" => "a\rb" },                          /users\[0\]\.gecos.*control/ ],
      "gecos NUL"                            => [ { "gecos" => "a\u0000b" },                      /users\[0\]\.gecos.*control/ ],
      "gecos escape sequence"                => [ { "gecos" => "a\e[2Jb" },                       /users\[0\]\.gecos.*control/ ],
      "home newline (passes the root prefix)" => [ { "home" => "/home/x\ntoor:x:0:0::/:/bin/sh" }, /users\[0\]\.home/ ],
      "home colon"                           => [ { "home" => "/var/lib/x:y" },                   /users\[0\]\.home.*':'/ ],
      "home dotdot"                          => [ { "home" => "/var/lib/../../etc" },             /users\[0\]\.home.*'\.\.'/ ],
      "shell newline"                        => [ { "shell" => "/bin/sh\ntoor:x:0:0::/:/bin/sh" }, /users\[0\]\.shell/ ],
      "shell colon"                          => [ { "shell" => "/bin/sh:x" },                     /users\[0\]\.shell.*':'/ ],
      "shell relative"                       => [ { "shell" => "bash" },                          /users\[0\]\.shell.*absolute/ ]
    }.each do |label, (overrides, message)|
      it "refuses #{label} with a readable error" do
        expect(errors_for("users" => [ user(overrides) ])).to match(message)
      end
    end

    it "accepts the field shapes shipped manifests use" do
      ok = user("name" => "postgres", "shell" => "/bin/bash", "home" => "/var/lib/postgresql",
                "gecos" => "Dev-cell sandboxed agent worker (no secrets, no push authority)")
      result = described_class.validate_only(yaml: yaml_for("users" => [ ok ]), node_module: mod)
      expect(result.validation_errors).to be_empty
    end
  end

  describe "reserved names and privileged groups" do
    %w[root pnadmin sshd nobody daemon mail].each do |name|
      it "refuses a user named #{name}" do
        expect(errors_for("users" => [ user("name" => name) ])).to match(/users\[0\]\.name "#{name}" is reserved/)
      end
    end

    %w[sudo disk shadow kmem root adm].each do |name|
      it "refuses declaring the privileged group #{name}" do
        expect(errors_for("groups" => [ { "name" => name } ])).to match(/groups\[0\]\.name "#{name}" is a privileged/)
      end

      it "refuses joining the privileged group #{name}" do
        expect(errors_for("users" => [ user("supplementary_groups" => [ name ]) ]))
          .to match(/users\[0\]\.supplementary_groups\[0\] "#{name}" is a privileged/)
      end

      it "refuses #{name} as a primary group" do
        expect(errors_for("users" => [ user("primary_group" => name) ]))
          .to match(/users\[0\]\.primary_group "#{name}" is a privileged/)
      end
    end

    it "still allows a device group such as video" do
      result = described_class.validate_only(
        yaml: yaml_for("groups" => [ { "name" => "video" } ],
                       "users" => [ user("supplementary_groups" => [ "video" ]) ]),
        node_module: mod
      )
      expect(result.validation_errors).to be_empty
    end
  end

  describe "sudoers fields" do
    let(:users) { [ user ] }

    {
      "a command with a newline adding a second rule" =>
        [ { "commands" => [ "/bin/true\npnadmin ALL=(ALL) NOPASSWD: /bin/sh" ] }, /sudoers\[0\]\.commands\[0\].*control/ ],
      "a command with a comma"     => [ { "commands" => [ "/bin/true, /bin/sh" ] }, /sudoers\[0\]\.commands\[0\].*","/ ],
      "a command with a colon"     => [ { "commands" => [ "/bin/true : h = /bin/sh" ] }, /sudoers\[0\]\.commands\[0\]/ ],
      "a command with '='"         => [ { "commands" => [ "/bin/x a=b" ] }, /sudoers\[0\]\.commands\[0\].*"="/ ],
      "a runas escaping its parens" => [ { "runas" => "root) NOPASSWD: ALL" }, /sudoers\[0\]\.runas/ ],
      "a runas with a newline"     => [ { "runas" => "root\nx" }, /sudoers\[0\]\.runas/ ],
      "a flag injecting a rule"    => [ { "flags" => [ "SETENV: /bin/sh\npnadmin ALL=(ALL) NOPASSWD" ] }, /sudoers\[0\]\.flags\[0\]/ ],
      "an unknown flag"            => [ { "flags" => [ "PASSWD" ] }, /sudoers\[0\]\.flags\[0\].*not an allowed sudoers tag/ ],
      "a grant escalating pnadmin" => [ { "user" => "pnadmin" }, /sudoers\[0\]\.user "pnadmin" is reserved/ ]
    }.each do |label, (overrides, message)|
      it "refuses #{label}" do
        expect(errors_for("users" => users, "sudoers" => [ grant(overrides) ])).to match(message)
      end
    end

    it "accepts a well-formed grant with an allowed flag" do
      result = described_class.validate_only(
        yaml: yaml_for("users" => users, "sudoers" => [ grant("flags" => [ "SETENV" ]) ]), node_module: mod
      )
      expect(result.validation_errors).to be_empty
    end
  end

  describe "a refused manifest never reaches a node" do
    it "persists no identity rows, so the node API serializes none" do
      result = described_class.import!(
        node_module: mod,
        yaml: yaml_for("users" => [ user("gecos" => "x\ntoor:x:0:0::/root:/bin/bash") ])
      )

      expect(result.ok?).to be false
      expect(result.error.to_s + Array(result.validation_errors).join).to match(/gecos/)
      expect(::System::ServiceUser.count).to eq(0)
      expect(::System::NodeModuleNodeApiSerializer.new(mod.reload).send(:serialize_module_users, mod)).to eq([])
    end
  end
end

RSpec.describe "IMP-01a0f109 model-level identity grammar" do # rubocop:disable RSpec/DescribeClass
  before do
    ::System::ServiceUser.delete_all
    ::System::ServiceGroup.delete_all
  end

  let(:group) { ::System::ServiceGroup.create!(groupname: "svcgrp", gid: 71_500) }

  def service_user(attrs = {})
    ::System::ServiceUser.new({ username: "svcmodel", uid: 71_501, primary_group: group,
                                shell: "/usr/sbin/nologin", home: "/var/lib/svcmodel", gecos: "ok" }.merge(attrs))
  end

  it "refuses a gecos, home or shell that would break a passwd line on any write path" do
    expect(service_user(gecos: "x\ntoor:x:0:0::/root:/bin/bash")).not_to be_valid
    expect(service_user(home: "/var/lib/x:y")).not_to be_valid
    expect(service_user(shell: "/bin/sh\nx")).not_to be_valid
    expect(service_user).to be_valid
  end

  it "refuses creating a reserved user or a privileged group" do
    expect(service_user(username: "pnadmin")).not_to be_valid
    expect(::System::ServiceGroup.new(groupname: "sudo", gid: 71_502)).not_to be_valid
  end

  it "refuses a sudoers grant whose command, runas or flag could leave its slot" do
    user = service_user.tap(&:save!)
    mod  = create(:system_node_module, name: "grant-mod")
    base = { node_module: mod, service_user: user, grant_id: "g", runas_user: "root",
             commands: [ "/usr/bin/id" ], flags: [] }

    expect(::System::SudoersGrant.new(base)).to be_valid
    expect(::System::SudoersGrant.new(base.merge(commands: [ "/bin/true\npnadmin ALL=(ALL) NOPASSWD: /bin/sh" ]))).not_to be_valid
    expect(::System::SudoersGrant.new(base.merge(runas_user: "root) ALL"))).not_to be_valid
    expect(::System::SudoersGrant.new(base.merge(flags: [ "SETENV: /bin/sh" ]))).not_to be_valid
  end
end
