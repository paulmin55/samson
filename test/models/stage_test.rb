require_relative '../test_helper'

describe Stage do
  subject { stages(:test_staging) }
  let(:stage) { subject }

  describe ".where_reference_being_deployed" do
    it "returns stages where the reference is currently being deployed" do
      project = projects(:test)
      stage = stages(:test_staging)
      author = users(:deployer)

      job = project.jobs.create!(user: author, commit: "a", command: "yes", status: "running")
      stage.deploys.create!(reference: "xyz", job: job)

      assert_equal [stage], Stage.where_reference_being_deployed("xyz")
    end
  end

  describe '.reorder' do
    let(:project) { projects(:test) }
    let(:stage1) { Stage.create!(project: project, name: 'stage1', order: 1) }
    let(:stage2) { Stage.create!(project: project, name: 'stage2', order: 2) }
    let(:stage3) { Stage.create!(project: project, name: 'stage3', order: 3) }

    it 'updates the order on stages' do
      Stage.reorder [stage3.id, stage2.id, stage1.id]

      stage1.reload.order.must_equal 2
      stage2.reload.order.must_equal 1
      stage3.reload.order.must_equal 0
    end

    it 'succeeds even if a stages points to a deleted stage' do
      stage1.update! next_stage_ids: [stage3.id]
      stage3.soft_delete!

      Stage.reorder [stage2.id, stage1.id]

      stage1.reload.order.must_equal 1
      stage2.reload.order.must_equal 0
    end
  end

  describe '#command' do
    describe 'adding a built command' do
      before do
        subject.stage_commands.build(command:
          Command.new(command: 'test')
        )

        subject.command_ids = [commands(:echo).id]
        subject.save!
        subject.reload
      end

      it 'add new command to the end' do
        subject.command.must_equal("#{commands(:echo).command}\ntest")
      end
    end

    describe 'adding + sorting a command' do
      before do
        command = Command.create!(command: 'test')

        subject.command_ids = [command.id, commands(:echo).id]
        subject.save!
        subject.reload
      end

      it 'joins all commands based on position' do
        subject.command.must_equal("test\n#{commands(:echo).command}")
      end
    end

    describe 'no commands' do
      before { subject.commands.clear }

      it 'is empty' do
        subject.command.must_be_empty
      end
    end
  end

  describe '#last_deploy' do
    let(:project) { projects(:test) }
    let(:stage) { stages(:test_staging) }

    it 'caches nil' do
      stage
      ActiveRecord::Relation.any_instance.expects(:first).returns nil
      stage.last_deploy.must_equal nil
      ActiveRecord::Relation.any_instance.expects(:first).never
      stage.last_deploy.must_equal nil
    end

    it 'returns the last deploy for the stage' do
      job = project.jobs.create!(command: 'cat foo', user: users(:deployer), status: 'succeeded')
      stage.deploys.create!(reference: 'master', job: job)
      job = project.jobs.create!(command: 'cat foo', user: users(:deployer), status: 'failed')
      deploy = stage.deploys.create!(reference: 'master', job: job)
      assert_equal deploy, stage.last_deploy
    end
  end

  describe '#last_successful_deploy' do
    let(:project) { projects(:test) }

    it 'caches nil' do
      subject
      ActiveRecord::Relation.any_instance.expects(:first).returns nil
      stage.last_successful_deploy.must_equal nil
      ActiveRecord::Relation.any_instance.expects(:first).never
      stage.last_successful_deploy.must_equal nil
    end

    it 'returns the last successful deploy for the stage' do
      successful_job = project.jobs.create!(command: 'cat foo', user: users(:deployer), status: 'succeeded')
      stage.deploys.create!(reference: 'master', job: successful_job)
      job = project.jobs.create!(command: 'cat foo', user: users(:deployer), status: 'failed')
      deploy = stage.deploys.create!(reference: 'master', job: successful_job)
      assert_equal deploy, stage.last_successful_deploy
    end
  end

  describe "#current_release?" do
    let(:project) { projects(:test) }
    let(:stage) { stages(:test_staging) }
    let(:author) { users(:deployer) }
    let(:job) { project.jobs.create!(user: author, commit: "x", command: "echo", status: "succeeded") }
    let(:releases) { Array.new(3).map { project.releases.create!(author: author, commit: "A") } }

    before do
      stage.deploys.create!(reference: "v124", job: job)
      stage.deploys.create!(reference: "v125", job: job)
    end

    it "returns true if the release was the last thing deployed to the stage" do
      assert stage.current_release?(releases[1])
    end

    it "returns false if the release is not the last thing deployed to the stage" do
      refute stage.current_release?(releases[0])
    end

    it "returns false if the release has never been deployed to the stage" do
      refute stage.current_release?(releases[2])
    end
  end

  describe "#create_deploy" do
    let(:user) { users(:deployer) }

    it "creates a new deploy" do
      deploy = subject.create_deploy(user, {reference: "foo"})
      deploy.reference.must_equal "foo"
    end

    it "creates a new job" do
      deploy = subject.create_deploy(user, {reference: "foo"})
      deploy.job.user.must_equal user
    end

    it "creates neither job nor deploy if one fails to save" do
      assert_no_difference "Deploy.count + Job.count" do
        subject.create_deploy(user, {reference: ""})
      end
    end
  end

  describe "#current_deploy" do
    it "is nil when not deploying" do
      subject.current_deploy.must_equal nil
    end

    it 'caches nil' do
      subject
      ActiveRecord::Relation.any_instance.expects(:first).returns nil
      subject.current_deploy.must_equal nil
      ActiveRecord::Relation.any_instance.expects(:first).never
      subject.current_deploy.must_equal nil
    end

    it "is there when deploying" do
      subject.deploys.first.job.update_column(:status, 'running')
      subject.current_deploy.must_equal subject.deploys.first
    end

    it "is there when waiting for buddy" do
      subject.deploys.first.job.update_column(:status, 'pending')
      subject.current_deploy.must_equal subject.deploys.first
    end
  end

  describe "#notify_email_addresses" do
    it "returns email addresses separated by a semicolon" do
      stage = Stage.new(notify_email_address: "a@foo.com; b@foo.com")
      stage.notify_email_addresses.must_equal ["a@foo.com", "b@foo.com"]
    end
  end

  describe 'unlocked_for/locked?/locked_for?' do
    describe 'with a lock' do
      before do
        subject.create_lock!(user: users(:deployer))
      end

      it 'is not included' do
        Stage.unlocked_for(users(:admin)).wont_include(subject)
      end

      it 'is locked?' do
        subject.reload.must_be(:locked?)
      end

      it 'locks other users out' do
        subject.reload.locked_for?(users(:admin)).must_equal true
      end

      it 'does not lock out the user who puts up the lock' do
        subject.reload.locked_for?(users(:deployer)).must_equal false
      end
    end

    describe 'with a global lock' do
      before do
        Lock.create!(user: users(:admin))
      end

      it 'is not empty' do
        Stage.unlocked_for(users(:admin)).wont_be_empty
      end

      it 'is not locked' do
        subject.wont_be(:locked?)
      end
    end

    it 'includes unlocked stage' do
      Stage.unlocked_for(users(:deployer)).must_include(subject)
    end

    it 'is not locked' do
      subject.wont_be(:locked?)
    end
  end

  describe "#next_stage" do
    let(:project) { Project.new }
    let(:stage1) { Stage.new(project: project) }
    let(:stage2) { Stage.new(project: project) }

    before do
      project.stages = [stage1, stage2]
    end

    it "returns the next stage of the project" do
      stage1.next_stage.must_equal stage2
    end

    it "returns nil if the current stage is the last stage" do
      stage2.next_stage.must_be_nil
    end
  end

  describe "#datadog_tags_as_array" do
    it "returns an array of the tags" do
      subject.datadog_tags = " foo; bar; baz "
      subject.datadog_tags_as_array.must_equal ["foo", "bar", "baz"]
    end

    it "uses only semicolon as separate" do
      subject.datadog_tags = " foo bar: baz "
      subject.datadog_tags_as_array.must_equal ["foo bar: baz"]
    end

    it "returns an empty array if no tags have been configured" do
      subject.datadog_tags = nil
      subject.datadog_tags_as_array.must_equal []
    end
  end

  describe "#send_datadog_notifications?" do
    it "returns true if the stage has a Datadog tag configured" do
      subject.datadog_tags = "env:beta"
      subject.send_datadog_notifications?.must_equal true
    end

    it "returns false if the stage does not have a Datadog tag configured" do
      subject.datadog_tags = nil
      subject.send_datadog_notifications?.must_equal false
    end
  end

  describe "#automated_failure_emails" do
    let(:user) { users(:super_admin) }
    let(:deploy) do
      deploy = subject.create_deploy(user, {reference: "commita"})
      deploy.job.fail!
      deploy
    end
    let(:previous_deploy) { deploys(:succeeded_test) }
    let(:emails) { subject.automated_failure_emails(deploy) }
    let(:simple_response) { Hashie::Mash.new(commits: [{commit: {author: {email: "pete@example.com"}}}]) }

    before do
      user.update_attribute(:integration, true)
      subject.update_column(:static_emails_on_automated_deploy_failure, "static@example.com")
      subject.update_column(:email_committers_on_automated_deploy_failure, true)
    end

    it "includes static emails and committer emails" do
      GITHUB.expects(:compare).with(anything, previous_deploy.reference, "commita").returns simple_response
      emails.must_equal ["static@example.com", "pete@example.com"]
    end

    it "is empty when deploy was a success" do
      deploy.job.success!
      emails.must_equal nil
    end

    it "is empty when last deploy was also a failure" do
      previous_deploy.job.fail!
      emails.must_equal nil
    end

    it "is empty when user was human" do
      user.update_attribute(:integration, false)
      emails.must_equal nil
    end

    it "includes committers when there is no previous deploy" do
      previous_deploy.delete
      emails.must_equal ["static@example.com"]
    end

    it "does not include commiiters if the author did not have a email" do
      GITHUB.expects(:compare).returns Hashie::Mash.new(commits: [{commit: {author: {}}}])
      emails.must_equal ["static@example.com"]
    end

    it "does not include commiiters when email_committers_on_automated_deploy_failure? if off" do
      subject.update_column(:email_committers_on_automated_deploy_failure, false)
      emails.must_equal ["static@example.com"]
    end

    it "does not have static when static is empty" do
      subject.update_column(:static_emails_on_automated_deploy_failure, "")
      GITHUB.expects(:compare).returns simple_response
      emails.must_equal ["pete@example.com"]
    end
  end

  describe ".build_clone" do
    before do
      subject.notify_email_address = "test@test.ttt"
      subject.flowdock_flows = [FlowdockFlow.new(name: "test", token: "abcxyz", stage_id: subject.id)]
      subject.datadog_tags = "xyz:abc"
      subject.new_relic_applications = [NewRelicApplication.new(name: "test", stage_id: subject.id)]
      subject.save

      @clone = Stage.build_clone(subject)
    end

    it "returns an unsaved copy of the given stage with exactly the same everything except id" do
      @clone.attributes.except("id").must_equal subject.attributes.except("id")
      @clone.id.wont_equal subject.id
    end

    it "copies over the new relic applications" do
      assert_equal @clone.new_relic_applications.map { |n| n.attributes.except("stage_id", "id") },
        subject.new_relic_applications.map { |n| n.attributes.except("stage_id", "id") }
    end
  end

  describe '#production?' do
    let(:stage) { stages(:test_production) }
    before { DeployGroup.stubs(enabled?: true) }

    it 'is true for stage with production deploy_group' do
      stage.update!(production: false)
      stage.production?.must_equal true
    end

    it 'is false for stage with non-production deploy_group' do
      stage = stages(:test_staging)
      stage.production?.must_equal false
    end

    it 'false for stage with no deploy_group' do
      stage.update!(production: false)
      stage.deploy_groups = []
      stage.production?.must_equal false
    end

    it 'fallbacks to production field when deploy groups was enabled without selecting deploy groups' do
      stage.deploy_groups = []
      stage.update!(production: true)
      stage.production?.must_equal true
      stage.update!(production: false)
      stage.production?.must_equal false
    end

    it 'fallbacks to production field when deploy groups was disabled' do
      DeployGroup.stubs(enabled?: false)
      stage.update!(production: true)
      stage.production?.must_equal true
      stage.update!(production: false)
      stage.production?.must_equal false
    end
  end

  describe '#datadog_monitors' do
    it "is empty by default" do
      stage.datadog_monitors.must_equal []
    end

    it "builds multiple monitors" do
      stage.datadog_monitor_ids = "1,2, 4"
      stage.datadog_monitors  .map(&:id).must_equal [1,2,4]
    end
  end

  describe '#save' do
    it 'touches the stage and project when only changing deploy_groups for cache invalidation' do
      stage_updated_at = stage.updated_at
      project_updated_at = stage.project.updated_at
      stage.deploy_groups << deploy_groups(:pod1)
      stage.save
      stage_updated_at.wont_equal stage.updated_at
      project_updated_at.wont_equal stage.project.updated_at
    end
  end

  describe "#ensure_ordering" do
    it "puts new stages to the back" do
      new = stage.project.stages.create! name: 'Newish'
      new.order.must_equal 1
    end
  end
end
