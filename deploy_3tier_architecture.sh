#!/bin/bash

# Source the variables
source ./variables.sh

# Create the resource group
status=$(az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --query "properties.provisioningState" -o tsv)
if [[ $status != "Succeeded" ]]; then
    echo "Error: Failed to create resource group."
    exit 1
fi
echo "Resource group created successfully."

# Create the virtual network with FrontendSubnet
status=$(az network vnet create --resource-group "$RESOURCE_GROUP" --name "$VNET_NAME" --address-prefix "$range_subnet" --subnet-name "$FE_SUBNET_NAME" --subnet-prefix "$frontend_subnet_cidr" --query "newVNet.provisioningState" -o tsv)
if [[ $status != "Succeeded" ]]; then
    echo "Error: Failed to create virtual network."
    exit 1
fi
echo "Virtual network created successfully."

# Create the BackendSubnet
status=$(az network vnet subnet create --resource-group "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" --name "$BE_SUBNET_NAME" --address-prefix "$backendend_subnet_cidr" --query "provisioningState" -o tsv)
if [[ $status != "Succeeded" ]]; then
    echo "Error: Failed to create BackendSubnet."
    exit 1
fi
echo "Backend subnet created successfully."

# Create the DatabaseSubnet
status=$(az network vnet subnet create --resource-group "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" --name "$DB_SUBNET_NAME" --address-prefix "$database_subnet_cidr" --query "provisioningState" -o tsv)
if [[ $status != "Succeeded" ]]; then
    echo "Error: Failed to create DatabaseSubnet."
    exit 1
fi
echo "Database subnet created successfully."


# Create Frontend, Backend, and Database NSGs
# Create Network Security Groups (NSGs) first
echo "Creating NSGs..."
az network nsg create --resource-group "$RESOURCE_GROUP" --name "$FE_NSG" --location "$LOCATION"
az network nsg create --resource-group "$RESOURCE_GROUP" --name "$BE_NSG" --location "$LOCATION"
az network nsg create --resource-group "$RESOURCE_GROUP" --name "$DB_NSG" --location "$LOCATION"

echo "NSGs created successfully."

# Create Network Interface Cards (NICs) next
echo "Creating Frontend NIC..."
az network nic create --resource-group "$RESOURCE_GROUP" --name "FrontendNIC" --vnet-name "$VNET_NAME" --subnet "$FE_SUBNET_NAME" --network-security-group "$FE_NSG"

echo "Frontend NIC created successfully."

echo "Creating Backend NIC..."
az network nic create --resource-group "$RESOURCE_GROUP" --name "BackendNIC" --vnet-name "$VNET_NAME" --subnet "$BE_SUBNET_NAME" --network-security-group "$BE_NSG"

echo "Backend NIC created successfully."

echo "Creating Database NIC..."
az network nic create --resource-group "$RESOURCE_GROUP" --name "DatabaseNIC" --vnet-name "$VNET_NAME" --subnet "$DB_SUBNET_NAME" --network-security-group "$DB_NSG"

echo "Database NIC created successfully."

echo "All NICs created successfully!"



# Create NSG rules
az network nsg rule create --resource-group "$RESOURCE_GROUP" --nsg-name "$FE_NSG" --name "AllowHTTPInbound" --priority 100 --direction Inbound --access Allow --protocol Tcp --destination-port-range 80 --source-address-prefix "*" --destination-address-prefix "*"
az network nsg rule create --resource-group "$RESOURCE_GROUP" --nsg-name "$FE_NSG" --name "AllowFrontendToBackendOutbound" --priority 200 --direction Outbound --access Allow --protocol Tcp --destination-port-range 8000 --source-address-prefix "*" --destination-address-prefix "$backend_subnet_cidr"
az network nsg rule create --resource-group "$RESOURCE_GROUP" --nsg-name "$BE_NSG" --name "AllowFrontendToBackendInbound" --priority 100 --direction Inbound --access Allow --protocol Tcp --destination-port-range 8000 --source-address-prefix "$frontend_subnet_cidr" --destination-address-prefix "*"
az network nsg rule create --resource-group "$RESOURCE_GROUP" --nsg-name "$BE_NSG" --name "AllowBackendToFrontendOutbound" --priority 200 --direction Outbound --access Allow --protocol Tcp --destination-port-range "80 8000" --source-address-prefix "*" --destination-address-prefix "$frontend_subnet_cidr"
az network nsg rule create --resource-group "$RESOURCE_GROUP" --nsg-name "$DB_NSG" --name "AllowMySQLInbound" --priority 100 --direction Inbound --access Allow --protocol Tcp --destination-port-range 3306 --source-address-prefix "$frontend_subnet_cidr" --destination-address-prefix "$backend_subnet_cidr"

# Create VMSS for frontend and backend
az vmss create --resource-group "$RESOURCE_GROUP" --name "chatappcli_FEVMSS" --image "$FE_IMAGE" --upgrade-policy-mode automatic --admin-username "$ADMIN_USERNAME" --admin-password "$ADMIN_PASSWORD" --instance-count 1 --location "$LOCATION" --vnet-name "$VNET_NAME" --subnet "$FE_SUBNET_NAME"
az vmss create --resource-group "$RESOURCE_GROUP" --name "chatappcli_BEVMSS" --image "$BE_IMAGE" --upgrade-policy-mode automatic --admin-username "$ADMIN_USERNAME" --admin-password "$ADMIN_PASSWORD" --instance-count 1 --location "$LOCATION" --vnet-name "$VNET_NAME" --subnet "$BE_SUBNET_NAME"

# Create Database VM
az vm create --resource-group "$RESOURCE_GROUP" --name "chatappDBVM" --image "$DB_IMAGE" --admin-username "$ADMIN_USERNAME" --admin-password "$ADMIN_PASSWORD" --size Standard_B2s --vnet-name "$VNET_NAME" --subnet "$DB_SUBNET_NAME" --location "$LOCATION" --security-type TrustedLaunch

# Create Backend Load Balancer
az network lb create --resource-group "$RESOURCE_GROUP" --name "chatappcli-BELB" --sku Basic --location "$LOCATION" --vnet-name "$VNET_NAME" --subnet "$BE_SUBNET_NAME" --private-ip-address "10.0.3.10"

# Create Application Gateway
az network application-gateway create --resource-group "$RESOURCE_GROUP" --name "chatappcli-applicationgateway" --sku Standard_V2 --capacity 2 --vnet-name "$VNET_NAME" --subnet "applicationgateway" --location "$LOCATION" --public-ip-address "FE-applicationgateway-publicip"

# Configure Application Gateway
az network application-gateway http-settings create --resource-group "$RESOURCE_GROUP" --gateway-name "chatappcli-applicationgateway" --name "FE-applicationgateway-httpSetting" --port 80 --protocol Http --cookie-based-affinity Disabled
az network application-gateway http-listener create --resource-group "$RESOURCE_GROUP" --gateway-name "chatappcli-applicationgateway" --name "FE-applicationgateway-httpListener" --frontend-port 80 --frontend-ip "FE-applicationgateway-publicip"
az network application-gateway rule create --resource-group "$RESOURCE_GROUP" --gateway-name "chatappcli-applicationgateway" --name "FE-applicationgateway-rule" --http-listener "FE-applicationgateway-httpListener" --rule-type Basic --address-pool "FE-applicationgateway-backendpool" --http-settings "FE-applicationgateway-httpSetting" --priority 100

echo "Script completed successfully."


echo "All resources created successfully."
