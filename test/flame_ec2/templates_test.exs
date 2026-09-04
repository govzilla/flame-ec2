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
end
