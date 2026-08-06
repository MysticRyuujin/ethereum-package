shared_utils = import_module("../shared_utils/shared_utils.star")
constants = import_module("../package_io/constants.star")
bootnodoor = import_module("../bootnodoor/bootnodoor_launcher.star")

MINIO_SERVICE_NAME = "enrscout-minio"
CRAWLER_SERVICE_NAME = "enrscout-crawler"
API_SERVICE_NAME = "enrscout-api"

MINIO_IMAGE = "minio/minio:latest"

MINIO_PORT_NUMBER = 9000
EL_DISCOVERY_PORT_NUMBER = 30303
CL_DISCOVERY_PORT_NUMBER = 30304
CL_LIBP2P_PORT_NUMBER = 30305
CRAWLER_METRICS_PORT_NUMBER = 9100
CRAWLER_PROBE_PORT_NUMBER = 9102
API_HTTP_PORT_NUMBER = 8080
API_METRICS_PORT_NUMBER = 9101

CL_UDP_DISCOVERY_PORT_ID = "cl-discovery"
CL_LIBP2P_PORT_ID = "cl-libp2p"

# Throwaway credentials for the enclave-local MinIO; never exposed publicly
S3_ACCESS_KEY = "minioadmin"
S3_SECRET_KEY = "minioadmin"
S3_BUCKET = "enrscout"

DEVNET_CONFIG_MOUNT_DIRPATH_ON_SERVICE = "/devnet-config"

# The min/max CPU/memory that the minio can use
MINIO_MIN_CPU = 100
MINIO_MAX_CPU = 1000
MINIO_MIN_MEMORY = 128
MINIO_MAX_MEMORY = 512

# The min/max CPU/memory that the crawler can use
CRAWLER_MIN_CPU = 100
CRAWLER_MAX_CPU = 1000
CRAWLER_MIN_MEMORY = 128
CRAWLER_MAX_MEMORY = 1024

# The min/max CPU/memory that the api can use
API_MIN_CPU = 100
API_MAX_CPU = 1000
API_MIN_MEMORY = 256
API_MAX_MEMORY = 2048

MINIO_USED_PORTS = {
    constants.HTTP_PORT_ID: shared_utils.new_port_spec(
        MINIO_PORT_NUMBER,
        shared_utils.TCP_PROTOCOL,
        shared_utils.HTTP_APPLICATION_PROTOCOL,
    )
}

CRAWLER_USED_PORTS = {
    constants.UDP_DISCOVERY_PORT_ID: shared_utils.new_port_spec(
        EL_DISCOVERY_PORT_NUMBER,
        shared_utils.UDP_PROTOCOL,
    ),
    constants.TCP_DISCOVERY_PORT_ID: shared_utils.new_port_spec(
        EL_DISCOVERY_PORT_NUMBER,
        shared_utils.TCP_PROTOCOL,
    ),
    CL_UDP_DISCOVERY_PORT_ID: shared_utils.new_port_spec(
        CL_DISCOVERY_PORT_NUMBER,
        shared_utils.UDP_PROTOCOL,
    ),
    CL_LIBP2P_PORT_ID: shared_utils.new_port_spec(
        CL_LIBP2P_PORT_NUMBER,
        shared_utils.TCP_PROTOCOL,
    ),
    constants.QUIC_DISCOVERY_PORT_ID: shared_utils.new_port_spec(
        CL_LIBP2P_PORT_NUMBER,
        shared_utils.UDP_PROTOCOL,
    ),
    constants.METRICS_PORT_ID: shared_utils.new_port_spec(
        CRAWLER_METRICS_PORT_NUMBER,
        shared_utils.TCP_PROTOCOL,
        shared_utils.HTTP_APPLICATION_PROTOCOL,
    ),
    constants.HTTP_PORT_ID: shared_utils.new_port_spec(
        CRAWLER_PROBE_PORT_NUMBER,
        shared_utils.TCP_PROTOCOL,
        shared_utils.HTTP_APPLICATION_PROTOCOL,
    ),
}

API_USED_PORTS = {
    constants.HTTP_PORT_ID: shared_utils.new_port_spec(
        API_HTTP_PORT_NUMBER,
        shared_utils.TCP_PROTOCOL,
        shared_utils.HTTP_APPLICATION_PROTOCOL,
    ),
    constants.METRICS_PORT_ID: shared_utils.new_port_spec(
        API_METRICS_PORT_NUMBER,
        shared_utils.TCP_PROTOCOL,
        shared_utils.HTTP_APPLICATION_PROTOCOL,
    ),
}


def launch_enrscout(
    plan,
    enrscout_params,
    el_cl_data_files_artifact_uuid,
    network_params,
    bootnodoor_enabled,
    participant_contexts,
    participant_configs,
    global_node_selectors,
    global_tolerations,
    port_publisher,
    additional_service_index,
    docker_cache_params,
):
    tolerations = shared_utils.get_tolerations(global_tolerations=global_tolerations)

    if bootnodoor_enabled:
        bootnodes = get_bootnodoor_bootnodes(plan)
    else:
        bootnodes = get_participant_bootnodes(participant_contexts, participant_configs)

    devnet_config_artifact_name = build_devnet_config_artifact(
        plan,
        el_cl_data_files_artifact_uuid,
        network_params,
        bootnodes,
    )

    minio_config = get_minio_config(global_node_selectors, tolerations)
    plan.add_service(MINIO_SERVICE_NAME, minio_config)

    crawler_config = get_crawler_config(
        enrscout_params,
        devnet_config_artifact_name,
        global_node_selectors,
        tolerations,
        docker_cache_params,
        port_publisher,
        additional_service_index,
    )
    plan.add_service(CRAWLER_SERVICE_NAME, crawler_config)

    api_config = get_api_config(
        enrscout_params,
        devnet_config_artifact_name,
        global_node_selectors,
        tolerations,
        docker_cache_params,
        port_publisher,
        additional_service_index,
    )
    plan.add_service(API_SERVICE_NAME, api_config)

    return get_metrics_jobs()


def get_bootnodoor_bootnodes(plan):
    bootnodes = []
    for endpoint in ["/cl-enr", "/el-enr", "/enode"]:
        response = plan.request(
            recipe=GetHttpRequestRecipe(
                endpoint=endpoint,
                port_id=constants.HTTP_PORT_ID,
            ),
            service_name=bootnodoor.SERVICE_NAME,
        )
        bootnodes.append(response["body"])
    return bootnodes


def get_participant_bootnodes(participant_contexts, participant_configs):
    bootnodes = []
    for participant_index, participant in enumerate(participant_contexts):
        _, cl_client, el_client, _ = shared_utils.get_client_names(
            participant, participant_index, participant_contexts, participant_configs
        )
        bootnodes.append(cl_client.enr)
        if el_client != None:
            bootnodes.append(el_client.enode)
            # discv4-only clients (ethereumjs, nethermind) leave enr empty
            if el_client.enr:
                bootnodes.append(el_client.enr)
    return bootnodes


def build_devnet_config_artifact(
    plan, el_cl_data_files_artifact_uuid, network_params, bootnodes
):
    bootnode_args = " ".join(["'{0}'".format(record) for record in bootnodes])
    commands = [
        "mkdir -p /devnet-config",
        "cp /network-configs/genesis.json /network-configs/config.yaml /network-configs/genesis_validators_root.txt /devnet-config/",
        "printf '%s\\n' '{0}' > /devnet-config/network_id.txt".format(
            network_params.network_id
        ),
        # enrscout needs the exact beacon genesis time under GENESIS_TIME; some
        # generated bundles carry only MIN_GENESIS_TIME
        "grep -q '^GENESIS_TIME:' /devnet-config/config.yaml || printf 'GENESIS_TIME: %s\\n' \"$(grep -oE 'MIN_GENESIS_TIME: [0-9]+' /devnet-config/config.yaml | grep -oE '[0-9]+')\" >> /devnet-config/config.yaml",
        # enrscout releases up to v0.0.3 read SECONDS_PER_SLOT, which newer genesis
        # bundles replaced with SLOT_DURATION_MS
        "grep -q '^SECONDS_PER_SLOT:' /devnet-config/config.yaml || ! grep -q '^SLOT_DURATION_MS:' /devnet-config/config.yaml || printf 'SECONDS_PER_SLOT: %s\\n' \"$(($(grep -oE '^SLOT_DURATION_MS: [0-9]+' /devnet-config/config.yaml | grep -oE '[0-9]+') / 1000))\" >> /devnet-config/config.yaml",
        "printf '%s\\n' {0} > /devnet-config/bootnodes.txt".format(bootnode_args),
    ]
    result = plan.run_sh(
        name="build-enrscout-devnet-config",
        description="Building the enrscout devnet config bundle",
        run=" && ".join(commands),
        files={
            "/network-configs": el_cl_data_files_artifact_uuid,
        },
        store=[
            StoreSpec(src="/devnet-config", name="enrscout-devnet-config"),
        ],
        wait=None,
    )
    return result.files_artifacts[0]


def get_minio_config(node_selectors, tolerations):
    return ServiceConfig(
        image=MINIO_IMAGE,
        ports=MINIO_USED_PORTS,
        cmd=["server", "/data"],
        env_vars={
            "MINIO_ROOT_USER": S3_ACCESS_KEY,
            "MINIO_ROOT_PASSWORD": S3_SECRET_KEY,
        },
        min_cpu=MINIO_MIN_CPU,
        max_cpu=MINIO_MAX_CPU,
        min_memory=MINIO_MIN_MEMORY,
        max_memory=MINIO_MAX_MEMORY,
        node_selectors=node_selectors,
        tolerations=tolerations,
        ready_conditions=ReadyCondition(
            recipe=GetHttpRequestRecipe(
                port_id=constants.HTTP_PORT_ID,
                endpoint="/minio/health/live",
            ),
            field="code",
            assertion="==",
            target_value=200,
            interval="5s",
            timeout="120s",
        ),
    )


def get_crawler_config(
    enrscout_params,
    devnet_config_artifact_name,
    node_selectors,
    tolerations,
    docker_cache_params,
    port_publisher,
    additional_service_index,
):
    public_ports = shared_utils.get_additional_service_standard_public_port(
        port_publisher,
        constants.HTTP_PORT_ID,
        additional_service_index,
        1,
    )

    cmd = [
        "--devnet-dir={0}".format(DEVNET_CONFIG_MOUNT_DIRPATH_ON_SERVICE),
        "--devnet-only",
        "--allow-private-ips",
        "--advertiser-networks=devnet",
        # Confine discovery to private ranges so an isolated devnet crawl can
        # never reach the public DHT
        "--netrestrict=10.0.0.0/8,172.16.0.0/12,192.168.0.0/16",
        "--advertiser-port-base={0}".format(EL_DISCOVERY_PORT_NUMBER),
        "--identity-dir=/identity",
        "--s3-endpoint={0}:{1}".format(MINIO_SERVICE_NAME, MINIO_PORT_NUMBER),
        "--s3-ssl=false",
        "--s3-bucket={0}".format(S3_BUCKET),
        "--s3-create-bucket",
        "--snapshot-interval=15s",
        "--metrics-addr=:{0}".format(CRAWLER_METRICS_PORT_NUMBER),
        "--probe-addr=:{0}".format(CRAWLER_PROBE_PORT_NUMBER),
        # Acceptable only on an isolated enclave-local devnet
        "--probe-allow-unauthenticated",
    ]

    if len(enrscout_params.crawler_extra_args) > 0:
        cmd.extend(enrscout_params.crawler_extra_args)

    return ServiceConfig(
        image=shared_utils.docker_cache_image_calc(
            docker_cache_params,
            enrscout_params.crawler_image,
        ),
        ports=CRAWLER_USED_PORTS,
        public_ports=public_ports,
        files={
            DEVNET_CONFIG_MOUNT_DIRPATH_ON_SERVICE: devnet_config_artifact_name,
        },
        cmd=cmd,
        env_vars={
            "S3_ACCESS_KEY": S3_ACCESS_KEY,
            "S3_SECRET_KEY": S3_SECRET_KEY,
        },
        private_ip_address_placeholder=constants.PRIVATE_IP_ADDRESS_PLACEHOLDER,
        min_cpu=CRAWLER_MIN_CPU,
        max_cpu=CRAWLER_MAX_CPU,
        min_memory=CRAWLER_MIN_MEMORY,
        max_memory=CRAWLER_MAX_MEMORY,
        node_selectors=node_selectors,
        tolerations=tolerations,
    )


def get_api_config(
    enrscout_params,
    devnet_config_artifact_name,
    node_selectors,
    tolerations,
    docker_cache_params,
    port_publisher,
    additional_service_index,
):
    public_ports = shared_utils.get_additional_service_standard_public_port(
        port_publisher,
        constants.HTTP_PORT_ID,
        additional_service_index,
        0,
    )

    cmd = [
        "--addr=:{0}".format(API_HTTP_PORT_NUMBER),
        "--networks=devnet",
        "--devnet-dir={0}".format(DEVNET_CONFIG_MOUNT_DIRPATH_ON_SERVICE),
        "--s3-endpoint={0}:{1}".format(MINIO_SERVICE_NAME, MINIO_PORT_NUMBER),
        "--s3-ssl=false",
        "--s3-bucket={0}".format(S3_BUCKET),
        "--refresh=15s",
        "--metrics-addr=:{0}".format(API_METRICS_PORT_NUMBER),
    ]

    if len(enrscout_params.api_extra_args) > 0:
        cmd.extend(enrscout_params.api_extra_args)

    return ServiceConfig(
        image=shared_utils.docker_cache_image_calc(
            docker_cache_params,
            enrscout_params.api_image,
        ),
        ports=API_USED_PORTS,
        public_ports=public_ports,
        files={
            DEVNET_CONFIG_MOUNT_DIRPATH_ON_SERVICE: devnet_config_artifact_name,
        },
        cmd=cmd,
        env_vars={
            "S3_ACCESS_KEY": S3_ACCESS_KEY,
            "S3_SECRET_KEY": S3_SECRET_KEY,
        },
        min_cpu=API_MIN_CPU,
        max_cpu=API_MAX_CPU,
        min_memory=API_MIN_MEMORY,
        max_memory=API_MAX_MEMORY,
        node_selectors=node_selectors,
        tolerations=tolerations,
        ready_conditions=ReadyCondition(
            recipe=GetHttpRequestRecipe(
                port_id=constants.HTTP_PORT_ID,
                endpoint="/livez",
            ),
            field="code",
            assertion="==",
            target_value=200,
            interval="5s",
            timeout="120s",
        ),
    )


def get_metrics_jobs():
    return [
        {
            "Name": CRAWLER_SERVICE_NAME,
            "Endpoint": "{0}:{1}".format(
                CRAWLER_SERVICE_NAME, CRAWLER_METRICS_PORT_NUMBER
            ),
            "MetricsPath": "/metrics",
            "Labels": {
                "service": CRAWLER_SERVICE_NAME,
            },
            "ScrapeInterval": "15s",
        },
        {
            "Name": API_SERVICE_NAME,
            "Endpoint": "{0}:{1}".format(API_SERVICE_NAME, API_METRICS_PORT_NUMBER),
            "MetricsPath": "/metrics",
            "Labels": {
                "service": API_SERVICE_NAME,
            },
            "ScrapeInterval": "15s",
        },
    ]
