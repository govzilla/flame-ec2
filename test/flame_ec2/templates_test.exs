defmodule FlameEC2.TemplatesTest do
  use ExUnit.Case

  doctest FlameEC2.Templates

  test "code loaded" do
    assert Code.loaded?(FlameEC2.Templates)
  end

  test "env template" do
    output = """

    MY_ENV_1=123

    MY_ENV_2=456

    MY_ENV_3=789

    """

    assert output == FlameEC2.Templates.env(vars: %{"MY_ENV_1" => "123", "MY_ENV_2" => "456", "MY_ENV_3" => "789"})
  end

  test "systemd template" do
    output = """
    [Unit]
    Description=flame_ec2 service
    After=local-fs.target network.target

    [Service]
    Type=simple
    WorkingDirectory=/srv/flame_ec2/release


    ExecStart=/srv/flame_ec2/release/bin/flame_ec2 start



    ExecStop=/srv/flame_ec2/release/bin/flame_ec2 stop


    Environment=LANG=en_US.utf8
    EnvironmentFile=/srv/flame_ec2/env
    LimitNOFILE=65535
    UMask=0027
    SyslogIdentifier=flame_ec2
    Restart=no
    ExecStopPost=/usr/bin/systemctl poweroff

    [Install]
    WantedBy=multi-user.target
    """

    assert output == FlameEC2.Templates.systemd_service(app: :flame_ec2)
  end

  test "systemd template (custom commands)" do
    output = """
    [Unit]
    Description=flame_ec2 service
    After=local-fs.target network.target

    [Service]
    Type=simple
    WorkingDirectory=/srv/flame_ec2/release


    ExecStart=ls



    ExecStop=ls


    Environment=LANG=en_US.utf8
    EnvironmentFile=/srv/flame_ec2/env
    LimitNOFILE=65535
    UMask=0027
    SyslogIdentifier=flame_ec2
    Restart=no
    ExecStopPost=/usr/bin/systemctl poweroff

    [Install]
    WantedBy=multi-user.target
    """

    assert output ==
             FlameEC2.Templates.systemd_service(app: :flame_ec2, custom_start_command: "ls", custom_stop_command: "ls")
  end

  test "start script" do
    systemd_service = FlameEC2.Templates.systemd_service(app: :flame_ec2)
    env = FlameEC2.Templates.env(vars: %{"MY_ENV_1" => "123"})

    output =
      FlameEC2.Templates.start_script(
        app: :flame_ec2,
        systemd_service: systemd_service,
        env: env,
        aws_region: "us-east-1",
        s3_bundle_url: "s3://code-bucket/code.tar.gz",
        s3_bundle_compressed?: true
      )

    assert String.contains?(output, systemd_service)
    assert String.contains?(output, env)
  end

  test "start script with user_data_pre_script" do
    systemd_service = FlameEC2.Templates.systemd_service(app: :flame_ec2)
    env = FlameEC2.Templates.env(vars: %{"MY_ENV_1" => "123"})

    pre_script = """
    echo "INFLUXDB_URL=http://influxdb:8086" >> /etc/default/telegraf
    echo "SERVICE_NAME=my_app" >> /etc/default/telegraf
    """

    output =
      FlameEC2.Templates.start_script(
        app: :flame_ec2,
        systemd_service: systemd_service,
        env: env,
        aws_region: "us-east-1",
        s3_bundle_url: "s3://code-bucket/code.tar.gz",
        s3_bundle_compressed?: true,
        user_data_pre_script: pre_script
      )

    # Verify pre-script is included
    assert String.contains?(output, "INFLUXDB_URL=http://influxdb:8086")
    assert String.contains?(output, "SERVICE_NAME=my_app")
    assert String.contains?(output, "# User-provided pre-script")
    assert String.contains?(output, "# End user-provided pre-script")

    # Verify pre-script appears before the main initialization
    {pre_script_pos, _} = :binary.match(output, "INFLUXDB_URL")
    {log_func_pos, _} = :binary.match(output, "log() {")
    assert pre_script_pos < log_func_pos
  end

  @tag :tmp_dir
  test "start script powers the instance off when the pre-script fails", %{tmp_dir: tmp_dir} do
    script = rendered_start_script(user_data_pre_script: "exit 23")
    {preamble_pos, _} = :binary.match(script, "log() {")
    preamble = binary_part(script, 0, preamble_pos)

    {status, systemctl_calls} = run_start_preamble(preamble, tmp_dir)

    assert status == 23
    assert systemctl_calls == "--no-block poweroff\n"
  end

  @tag :tmp_dir
  test "start script powers the instance off when later initialization fails", %{tmp_dir: tmp_dir} do
    script = rendered_start_script()
    {preamble_pos, _} = :binary.match(script, "log() {")
    preamble = binary_part(script, 0, preamble_pos) <> "false\n"

    {status, systemctl_calls} = run_start_preamble(preamble, tmp_dir)

    assert status == 1
    assert systemctl_calls == "--no-block poweroff\n"
  end

  @tag :tmp_dir
  test "start script does not power the instance off after successful initialization", %{tmp_dir: tmp_dir} do
    script = rendered_start_script()
    {preamble_pos, _} = :binary.match(script, "log() {")
    preamble = binary_part(script, 0, preamble_pos)

    {status, systemctl_calls} = run_start_preamble(preamble, tmp_dir)

    assert status == 0
    assert systemctl_calls == ""
  end

  test "start script without user_data_pre_script" do
    systemd_service = FlameEC2.Templates.systemd_service(app: :flame_ec2)
    env = FlameEC2.Templates.env(vars: %{"MY_ENV_1" => "123"})

    output =
      FlameEC2.Templates.start_script(
        app: :flame_ec2,
        systemd_service: systemd_service,
        env: env,
        aws_region: "us-east-1",
        s3_bundle_url: "s3://code-bucket/code.tar.gz",
        s3_bundle_compressed?: true
      )

    # Verify no pre-script placeholder text appears
    refute String.contains?(output, "User-provided pre-script")
  end

  test "start script creates separate log and release tmp directories" do
    systemd_service = FlameEC2.Templates.systemd_service(app: :my_app)
    env = FlameEC2.Templates.env(vars: %{"MY_ENV_1" => "123"})

    output =
      FlameEC2.Templates.start_script(
        app: :my_app,
        systemd_service: systemd_service,
        env: env,
        aws_region: "us-east-1",
        s3_bundle_url: "s3://code-bucket/code.tar.gz",
        s3_bundle_compressed?: true
      )

    assert output =~ ~s(LOG_DIR="/home/ubuntu/my_app/log")
    assert output =~ ~s(RELEASE_TMP_DIR="/home/ubuntu/my_app/tmp")
    assert output =~ ~s(chmod 0700 "${RELEASE_TMP_DIR}")
    assert output =~ ~s(if id ubuntu >/dev/null 2>&1; then)
    assert output =~ ~s(chown ubuntu:ubuntu "${LOG_DIR}")
    assert output =~ ~s(chmod 2775 "${LOG_DIR}")
    assert output =~ ~s(leaving ${LOG_DIR} owned by root)
  end

  defp rendered_start_script(opts \\ []) do
    systemd_service = FlameEC2.Templates.systemd_service(app: :flame_ec2)
    env = FlameEC2.Templates.env(vars: %{"MY_ENV_1" => "123"})

    FlameEC2.Templates.start_script(
      [
        app: :flame_ec2,
        systemd_service: systemd_service,
        env: env,
        aws_region: "us-east-1",
        s3_bundle_url: "s3://code-bucket/code.tar.gz",
        s3_bundle_compressed?: true
      ] ++ opts
    )
  end

  defp run_start_preamble(preamble, tmp_dir) do
    script_path = Path.join(tmp_dir, "start-preamble.sh")
    systemctl_path = Path.join(tmp_dir, "systemctl")
    calls_path = Path.join(tmp_dir, "systemctl-calls")

    File.write!(script_path, preamble)

    File.write!(
      systemctl_path,
      "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"#{calls_path}\"\n"
    )

    File.chmod!(systemctl_path, 0o755)

    path = tmp_dir <> ":" <> System.fetch_env!("PATH")
    {_output, status} = System.cmd("sh", [script_path], env: [{"PATH", path}], stderr_to_stdout: true)

    {status, if(File.exists?(calls_path), do: File.read!(calls_path), else: "")}
  end
end
