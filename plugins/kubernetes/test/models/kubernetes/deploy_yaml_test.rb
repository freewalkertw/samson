require_relative "../../test_helper"

SingleCov.covered!

describe Kubernetes::DeployYaml do
  let(:doc) { kubernetes_release_docs(:test_release_pod_1) }
  let(:yaml) { Kubernetes::DeployYaml.new(doc) }

  before do
    kubernetes_fake_raw_template
    doc.kubernetes_release.deploy_id = 123
  end

  describe "#resource_name" do
    it 'is deployment' do
      yaml.resource_name.must_equal 'deployment'
    end

    it 'knows if it is a DaemonSet' do
      yaml.send(:template).kind = 'DaemonSet'
      yaml.resource_name.must_equal 'daemon_set'
    end
  end

  describe "#to_hash" do
    it "works" do
      result = yaml.to_hash
      result.size.must_equal 3

      spec = result.fetch(:spec)
      spec.fetch(:uniqueLabelKey).must_equal "rc_unique_identifier"
      spec.fetch(:replicas).must_equal doc.replica_target
      spec.fetch(:template).fetch(:metadata).fetch(:labels).must_equal(
        revision: "1a6f551a2ffa6d88e15eef5461384da0bfb1c194",
        tag: "v123",
        pre_defined: "foobar",
        release_id: doc.kubernetes_release_id.to_s,
        project: "foo",
        project_id: doc.kubernetes_release.project_id.to_s,
        role_id: doc.kubernetes_role_id.to_s,
        role: "app_server",
        deploy_group: 'pod1',
        deploy_group_id: doc.deploy_group_id.to_s,
        deploy_id: "123",
      )

      metadata = result.fetch(:metadata)
      metadata.fetch(:namespace).must_equal 'pod1'
      metadata.fetch(:labels).must_equal(
        project_id: doc.kubernetes_release.project_id.to_s,
        revision: "1a6f551a2ffa6d88e15eef5461384da0bfb1c194",
        tag: "v123",
        deploy_id: "123",
        project: "foo",
        role: "app_server",
        deploy_group: "pod1",
      )
    end

    it "works without selector" do
      assert doc.raw_template.sub!('selector:', 'no_selector:')
      result = yaml.to_hash
      result.fetch(:spec).fetch(:selector).fetch(:matchLabels).keys.sort.must_equal([:deploy_group, :deploy_id, :project, :project_id, :revision, :role, :tag].sort)
    end

    it "works without labels" do
      yaml.send(:template).metadata.labels = nil
      result = yaml.to_hash
      result.fetch(:metadata).fetch(:labels).keys.sort.must_equal([:deploy_id, :project, :project_id, :role, :deploy_group, :revision, :tag].sort)
    end

    describe "deployment" do
      it "fails when deployment section is missing" do
        assert doc.raw_template.sub!('Deployment', 'Foobar')
        e = assert_raises Samson::Hooks::UserError do
          yaml.to_hash
        end
        e.message.must_include "has 0 Deployment sections, having 1 section is valid"
      end

      it "fails when multiple deployment sections are present" do
        doc.raw_template.replace("#{doc.raw_template}\n#{doc.raw_template}")
        e = assert_raises Samson::Hooks::UserError do
          yaml.to_hash
        end
        e.message.must_include "has 2 Deployment sections, having 1 section is valid"
      end
    end

    describe "containers" do
      let(:result) { yaml.to_hash }
      let(:container) { result.fetch(:spec).fetch(:template).fetch(:spec).fetch(:containers).first }

      it "overrides image" do
        container.fetch(:image).must_equal(
          'docker-registry.example.com/test@sha256:5f1d7c7381b2e45ca73216d7b06004fdb0908ed7bb8786b62f2cdfa5035fde2c'
        )
      end

      it "copies resource values" do
        container.fetch(:resources).must_equal(
          limits:{
            memory: "100Mi",
            cpu: 1.0
          }
        )
      end

      it "fills then environment with string values" do
        env = container.fetch(:env)
        env.map { |x| x.fetch(:name) }.sort.must_equal(
          [:REVISION, :TAG, :PROJECT, :ROLE, :DEPLOY_ID, :DEPLOY_GROUP, :POD_NAME, :POD_NAMESPACE, :POD_IP].sort
        )
        env.map { |x| x[:value] }.map(&:class).map(&:name).sort.uniq.must_equal(["NilClass", "String"])
      end

      it "removes : in env values since they would not validate against kubernetes (([A-Za-z0-9][-A-Za-z0-9_.]*)?[A-Za-z0-9])?" do
        doc.deploy_group.update_column(:env_value, 'foo:bar')
        container.fetch(:env).detect { |v| break v if v[:name] == :DEPLOY_GROUP }.fetch(:value).must_equal 'foo-bar'
      end

      it "fails without containers" do
        assert doc.raw_template.sub!("      containers:\n      - {}", '')
        e = assert_raises Samson::Hooks::UserError do
          yaml.to_hash
        end
        e.message.must_include "has 0 containers, having 1 section is valid"
      end

      # https://github.com/zendesk/samson/issues/966
      it "allows multiple containers, even though they will not be properly replaced" do
        assert doc.raw_template.sub!("containers:\n      - {}", "containers:\n      - {}\n      - {}")
        yaml.to_hash
      end

      it "merges existing env settings" do
        yaml.send(:template).spec.template.spec.containers[0].env = [{name: 'Foo', value: 'Bar'}]
        keys = container.fetch(:env).map(&:to_h).map { |x| x.fetch(:name) }
        keys.must_include 'Foo'
        keys.size.must_be :>, 5
      end
    end

    describe "daemon_set" do
      it "does not add replicas since they are not supported" do
        yaml.send(:template).kind = 'DaemonSet'
        result = yaml.to_hash
        refute result.key?(:replicas)
      end
    end
  end
end
