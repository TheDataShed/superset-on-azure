# superset-on-azure

## Prerequisites

This solution was developed/tested using the following:

- [Terraform](https://www.terraform.io/downloads.html) (v1.0.6)
- [Docker](https://docs.docker.com/engine/install/) (v20.10.8)
- [Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli) (v2.28.0)
- [kubectl](https://v1-18.docs.kubernetes.io/docs/tasks/tools/install-kubectl/) (v1.20.2)
- [envsubst](https://www.man7.org/linux/man-pages/man1/envsubst.1.html) (v0.19.8.1)
- [jq](https://stedolan.github.io/jq/download/) (v1.6)

## Infrastructure

The following commands _should_ get your infrastructure set up.

Good luck! 🤞

1. Perform an interactive login to Azure using the CLI:

    ```bash
    az login
    ```

    This should open your preferred browser with a prompt to log in to your account.

1. Now you have authenticated to Azure you can get cracking with the Terraform:

    ```bash
    terraform init
    ```

1. Now let's ask Terraform to provision the various resources.

    ```bash
    terraform apply
    ```

    Sanity check the output and respond appropriately (most likely with a `yes`, 'cause you want
     your Superset resources, right?)

1. Go make yourself a brew ☕.

    The provisioning might take a while (the Redis instance seems to be the culprit responsible for
     the significant wait time at a whopping 17 minutes last time I tried. Bonkers).

## Superset Container

1. Get the `acr_login_server` value from Terraform and assign it to an environment variable:

    ```bash
    export ACR_LOGIN_SERVER=$(terraform output -raw acr_login_server)
    ```

1. Have a quick sanity check of the variable value:

    ```bash
    echo $ACR_LOGIN_SERVER
    ```

1. Log in to the Azure Container Registry (ACR):

    ```bash
    az acr login --name $ACR_LOGIN_SERVER
    ```

1. Build the Superset Docker container:

    ```bash
    docker build --tag $ACR_LOGIN_SERVER/superset_base .
    ```

1. Push the container to the ACR:

    ```bash
    docker push $ACR_LOGIN_SERVER/superset_base
    ```

## Deploy Superset to Your Azure Kubernetes Service (AKS)

Before we begin it is important to remind you, dear reader, that this whole thing is a demonstration
 on how to deploy Superset to Azure. It is **not** illustrating best practices, and a prime example
 of this is shown in step 1 below where we will be grabbing a secret from a secure KeyVault, and
 assigning it to an environment variable. Hmmm...

1. Set up the environment variables:

    ```bash
    export RESOURCE_GROUP_NAME=$(terraform output -raw resource_group_name)
    export AKS_CLUSTER_NAME=$(terraform output -raw aks_cluster_name)
    export ACR_LOGIN_SERVER=$(terraform output -raw acr_login_server)
    export SUPERSET_WEB_IP=$(terraform output -raw superset_web_ip)
    export DATABASE_HOST=$(terraform output -raw databse_host)
    export DATABASE_ADMIN_USERNAME=$(terraform output -raw database_admin_username)
    export DATABASE_ADMIN_PASSWORD_SECRET_ID=$(terraform output -raw database_admin_password_secret_id)
    export DATABASE_ADMIN_PASSWORD=$(az keyvault secret show --id $DATABASE_ADMIN_PASSWORD_SECRET_ID | jq -r .value)
    export REDIS_HOST=$(terraform output -raw redis_host)
    export REDIS_PORT=$(terraform output -raw redis_port)
    ```

1. Connect to the AKS cluster:

    ```bash
    az aks get-credentials --resource-group $RESOURCE_GROUP_NAME --name $AKS_CLUSTER_NAME
    ```

1. Create the namespace:

    ```bash
    kubectl apply --filename kubernetes/namespace.yaml
    ```

1. Set up the services:

    ```bash
    cat kubernetes/services.yaml | envsubst | kubectl apply --filename -
    ```

    **Note:** this uses `envsubst` to perform token replacement within the `*.yaml` files before
     piping them in to `kubectl` via `stdin`.

1. Set up the secrets:

    ```bash
    cat kubernetes/secrets.yaml | envsubst | kubectl apply --filename -
    ```

1. Set up the config map (environment variables):

    ```bash
    cat kubernetes/config.yaml | envsubst | kubectl apply --filename -
    ```

1. Set up the initialisation job (this performs tasks like the initial database object creation):

    ```bash
    cat kubernetes/job.yaml | envsubst | kubectl apply --filename -
    ```

1. Set up the superset application:

    ```bash
    cat kubernetes/deployment.yaml | envsubst | kubectl apply --filename -
    ```

1. Get the URL for the Superset Application:

    ```bash
    echo http://$SUPERSET_WEB_IP
    ```

1. Go have fun on with your new Superset instance! 🎉
