defmodule FlameEC2 do
  @moduledoc """
  A `FLAME.Backend` using [AWS EC2](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/concepts.html) machines.

  ## How Does It Work?

  `FlameEC2` loads a release bundle that is stored in S3, and runs this release on a child node that it raises.
  The release will always be run with the built in release start command, with the environment marking it as a FLAME child.

  To facilitate shutdown of the node, `FlameEC2` runs the release under a systemd service, which is installed with a Post Stop hook
  that will automatically run a shutdown command on the instance when the release is stopped. This, in combination with setting the
  `"InstanceInitiatedShutdownBehavior"` to `"terminate"`, guarantees that when the release is stopped, the instance will trigger its
  shutdown and termination behavior.

  ## Usage

  To use, you must tell FLAME to use the `FlameEC2` backend by default.
  This can be set via application configuration in your `config/runtime.exs` withing a `:prod` block:

  ```elixir
  if config_env() == :prod do
    config :flame, :backend, FlameEC2
    ...
  end
  ```

  You must ensure that the IAM Role of whatever is running this backend has access to all of the necessary APIs.
  The following is a minimal IAM Policy recommended to allow the backend to access all required APIs:

  ```json
  {
      "Version": "2012-10-17",
      "Statement": [
          {
              "Sid": "ec2RunInstances",
              "Effect": "Allow",
              "Action": [
                  "ec2:DescribeTags",
                  "ec2:CreateTags",
                  "ec2:DeleteTags",
                  "ec2:RunInstances"
              ],
              "Resource": "*"
          },
          {
              "Sid": "ssmParameters",
              "Effect": "Allow",
              "Action": [
                  "ssm:GetParameters"
              ],
              "Resource": "*"
          },
          {
              "Sid": "iamRolePassing",
              "Effect": "Allow",
              "Action": [
                  "iam:PassRole"
              ],
              "Resource": [
                  "arn:aws:iam::*:instance-profile/*",
                  "arn:aws:iam::*:role/*"
              ],
              "Condition": {
                  "StringEquals": {
                      "iam:PassedToService": "ec2.amazonaws.com"
                  }
              }
          },
          {
              "Sid": "s3GetRelease",
              "Effect": "Allow",
              "Action": [
                  "s3:ListBucket",
                  "s3:GetObject"
              ],
              "Resource": "*"
          }
      ]
  }
  ```

  ## Configuration

  Configuration of the backend mirrors a subset of the
  [AWS EC2 LaunchInstance API](https://docs.aws.amazon.com/AWSEC2/latest/APIReference/API_RunInstances.html) options,
  to allow us to raise a machine properly.

  All of the configurations may be automatically set to the current instance's details by setting `auto_configure` to true:

  ```elixir
  config :flame, FlameEC2, auto_configure: true
  ...
  ```

  If you'd like to manually configure the details in your pool, you can read about the available configurations below.

  ### Required Configurations

  * `:s3_bundle_url` - The S3 URL of your release bundle.
  This value must be set in order to ensure that we can start the application properly on the child node.
  The bundle is expected to either be a directory that will be synced locally onto the child node,
  or a `.tar.gz` file that will be copied to the node and decompressed.

  * `:app` - The name of your application. Defaults to `System.get_env("RELEASE_NAME")`.
  If this environment variable is not set for some reason, this value must be set in the configuration.

  * `:image_id` - The ID of the AMI to use. This is a required attribute if you are not using a launch template, and has no default.

  * `:launch_template_id` - The ID of the Launch Template to use. This is a required attribute if you are not using an image id, and has no default.

  * `:launch_template_version` - The version number of the launch template, or "$Default", or "$Latest". Defaults to "$Default".

  * `:subnet_id` - The subnet ID for the attached network interface. This is required in order to properly communicate with the instance.

  * `:security_group_id` - The security group ID for the attached network interface. This is required in order to properly communicate with the instance.

  ### Optional Configurations

  * `:boot_timeout` - A timeout for booting a new node. Defaults to 120_000 (2 minutes).
  **Note!** The boot timeout must account for things like the actual initialization of an instance.
  Instances can take a couple of minutes to move from "Pending" to "Running" depending on capacity,
  and that doesn't include the actual instance initialization and the script that needs to run to set
  up the release on the machine. When using FlameEC2, you may want to consider setting this value to something
  that is higher to avoid timeout issues due to slowness of machine startups, or setting the pool minimum to 1
  to ensure that you have a "warm" pool of instances that can run tasks.

  * `:instance_type` - The instance type that should be used. Defaults to "t3.nano", which falls under the AWS free tier,
  however, you likely want to change this to something that's more appropriate for your pool's workload.

  * `:associate_public_ip_address` - Whether the runner's network interface should receive a public IPv4 address.
  Defaults to `false`. Enable this only when the selected subnet reaches the internet through an internet gateway
  and the runner needs direct internet access; private subnets with NAT should keep the default.

  * `:iam_instance_profile` - The ARN of the instance profile to assign to this machine.
  You must ensure that this instance profile is set to a profile which can access whatever your FLAME nodes will need.
  When auto-configured, it will be set to the current machine's instance profile, however, in some cases this profile may
  be too broad and you may want to create a role specific to the FLAME nodes.

  * `:key_name` - The name of the key pair to use for you to be able to connect to the instance.
  This is not required, however, an instance that was created without a key pair will be inaccessible without another way to log in.

  * `:instance_metadata_url` - The EC2 instance metadata URL. This is used when auto-configuring the pool with the `auto_configure` configuration set to `true`.
  Defaults to "http://169.254.169.254/latest/meta-data/" (note the trailing slash), which is the internal EC2 metadata URL.
  This can be adjusted for local testing, but likely does not need to be adjusted outside of this use case.

  * `:instance_metadata_token_url` - The EC2 instance metadata token URL. This is used when auto-configuring the pool with the `auto_configure` configuration set to `true`.
  Defaults to "http://169.254.169.254/latest/api/token", which is the internal EC2 metadata token URL.
  This can be adjusted for local testing, but likely does not need to be adjusted outside of this use case.

  * `:ec2_service_endpoint` - The URL of the EC2. Defaults to "https://ec2.amazonaws.com/", which is the AWS EC2 endpoint.
  This can be adjusted for local testing, but likely does not need to be adjusted outside of this use case.

  * `:user_data_pre_script` - A shell script that runs at the beginning of the EC2 UserData,
  before FlameEC2 initialization. Use this to configure system settings, write configuration
  files (like `/etc/default/*` for monitoring agents), or perform other setup tasks that
  must complete before the FLAME runner starts. It runs as root under `/bin/sh`, after
  `set -e` and before FlameEC2 defines its `log` helper or installs the AWS CLI. A failing
  command aborts runner initialization, powers the instance off, and leaves its output in
  `/var/log/cloud-init-output.log`; the shutdown marker also uses the `flame_ec2_init` journal
  tag. The script counts against EC2's 16 KiB raw UserData limit together with the generated
  FlameEC2 script.

  Example - configuring telegraf and vector for metrics/logging:

  ```elixir
  config :flame, FlameEC2,
    user_data_pre_script: \"\"\"
    echo "INFLUXDB_URL=http://influxdb.internal:8086" >> /etc/default/telegraf
    echo "SERVICE_NAME=my_app" >> /etc/default/telegraf
    echo "SERVICE_ROLE=flame_worker" >> /etc/default/telegraf

    echo "SERVICE_NAME=my_app" >> /etc/default/vector
    echo "SERVICE_ROLE=flame_worker" >> /etc/default/vector
    \"\"\"
  ```

  ## Application runtime directories

  FlameEC2 creates `/home/ubuntu/{app}/log` for application file loggers and makes
  files created there readable by the `ubuntu` group when that user exists. This is
  suitable for a log shipper in that group; FlameEC2 itself does not configure an
  application logger.

  It also creates a separate, root-only `/home/ubuntu/{app}/tmp` directory and exports
  it as `RELEASE_TMP`. Elixir release scripts use that directory for generated runtime
  configuration, not for application logs. A `RELEASE_TMP` value supplied explicitly
  through `:env` takes precedence over the default.

  ## Environment Variables

  The FLAME EC2 machines *do not* inherit the environment variables of the parent.
  You must explicit provide the environment that you would like to forward to the
  machine. For example, if your FLAME's are starting your Ecto repos, you can copy
  the env from the parent:

  ```elixir
  config :flame, FlameEC2,
    env: %{
      "DATABASE_URL" => System.fetch_env!("DATABASE_URL"),
      "POOL_SIZE" => "1"
    }
  ```

  Or pass the env to each pool:

  ```elixir
  {FLAME.Pool,
    name: MyRunner,
    backend: {FlameEC2, env: %{"DATABASE_URL" => System.fetch_env!("DATABASE_URL")}}
  }
  ```
  """
  @behaviour FLAME.Backend

  import FlameEC2.Utils

  alias FlameEC2.BackendState
  alias FlameEC2.EC2Api
  alias FlameEC2.Utils

  require Logger

  @impl true
  def init(opts) do
    app_config = Application.get_env(:flame, __MODULE__) || []
    {:ok, BackendState.new(opts, app_config)}
  end

  @impl true
  # The following TODO is from `FLAME.FlyBackend`. We should track it to ensure that we mirror the behavior properly.
  # TODO explore spawn_request
  def remote_spawn_monitor(%BackendState{} = state, term) do
    case term do
      func when is_function(func, 0) ->
        {pid, ref} = Node.spawn_monitor(state.runner_node_name, func)
        {:ok, {pid, ref}}

      {mod, fun, args} when is_atom(mod) and is_atom(fun) and is_list(args) ->
        {pid, ref} = Node.spawn_monitor(state.runner_node_name, mod, fun, args)
        {:ok, {pid, ref}}

      other ->
        raise ArgumentError,
              "expected a null arity function or {mod, func, args}. Got: #{inspect(other)}"
    end
  end

  @impl true
  def system_shutdown do
    # When creating the instance, we set InstanceInitiatedShutdownBehavior to `terminate`.
    # This is used to ensure that on instance shutdown, we terminate the instance completely.
    # Using this policy, we can set up our child node to run our app using systemd,
    # and add a post stop hook to completely shut down our node.
    # This will let us simplify not leaving orphaned nodes alive.
    System.stop()
  end

  @impl true
  def remote_boot(%BackendState{parent_ref: parent_ref} = state) do
    {resp, req_connect_time} =
      with_elapsed_ms(fn ->
        EC2Api.run_instances!(state)
      end)

    Utils.log(state.config, "#{inspect(__MODULE__)} #{inspect(node())} EC2 instance created in #{req_connect_time}ms")

    remaining_connect_window = state.config.boot_timeout - req_connect_time

    case resp do
      %{"instanceId" => instance_id, "privateIpAddress" => ip} ->
        new_state =
          %BackendState{
            state
            | runner_instance_id: instance_id,
              runner_instance_ip: ip
          }

        remote_terminator_pid =
          receive do
            {^parent_ref, {:remote_up, remote_terminator_pid}} ->
              remote_terminator_pid
          after
            remaining_connect_window ->
              Logger.error("failed to connect to EC2 instance within #{state.config.boot_timeout}ms")

              exit(:timeout)
          end

        new_state = %BackendState{
          new_state
          | remote_terminator_pid: remote_terminator_pid,
            runner_node_name: node(remote_terminator_pid)
        }

        {:ok, remote_terminator_pid, new_state}

      other ->
        {:error, other}
    end
  end

  @impl true
  def handle_info(msg, %BackendState{} = state) do
    Utils.log(state.config, "Missed message sent to FlameEC2 Process #{self()}: #{inspect(msg)}")
    {:noreply, state}
  end
end
