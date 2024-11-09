#!/usr/bin/env bash

#=============================
# As an SA, you need to perform demos and online sessions and workshops which require a lab environment to be available
# This script is created to automate the installation of all required resources for the Rancher management cluster master node.
# The resources to be installed using this scripts are as follow:
#   - One or more Dowstream clusters
# The output of this script will be the commands used to import the clusters to the Rancher Manager
#   - dsc-01-with-certificate: 
#   - dsc-01-without-certificate: 
#   - dsc-02-with-certificate: 
#   - dsc-02-without-certificate: 
#=============================

# Create a Usage Function to be used in case of error or miss-configuration to advise on the usage of the script
usage() {
    echo ""
    
    echo ""
}

#Read passed arguments and pass it to the script
while [ $# -gt 0 ]; do 
  case $1 in
    # Match on Help 
    -h|--help)
      usage
      exit 0
      ;;
    # Match on dsc_count
    --dsc_count)
      dsc_count="${2:-}"
      ;;
    # Print error on un-matched passed argument
    *)
      echo "argument is ${1}"
      echo "Error - Invalide argument provided - Provided argument is ${1}. Please provide all correct arguments"
      usage
      exit 1
      ;;
  esac
  shift 2 
done

# Validate if empty and print usage function in case arguments are empty


#==============================

#--------------------#
#--- Start Script----#
#--------------------#

#==============================

# Echo Starting Script
echo $BLACK      "=====================================================" $RESET
echo $DARK_GREEN "--------------     Start Of Script    ---------------" $RESET
echo $DARK_GREEN "Configuring SUSE Rancher Lab Environment On GCP Cloud" $RESET
echo $GREEN      "-----------------------------------------------------" $RESET
echo $BLACK      "=====================================================" $RESET
echo $GREEN  "  " $RESET

#=================================================================================================

#--------------------------------------
### 1- Creating The downstream clusters
#--------------------------------------

echo $GREEN  "  " $RESET
echo $GREEN  "1- Create activity number 1 ...  " $RESET

# Create VPC
echo $ORANGE "   Creating somthing ..." $RESET

echo $DARK_GREEN "      somthing Created" $RESET

#------------------------------------------

# Print end message
echo $GREEN "  " $RESET
echo $BLUE  "         All Activiy number 1 has ben Created" $RESET
echo $BLACK "=============================================" $RESET

#=================================================================================================


echo $GREEN  "  " $RESET
echo $BLACK "=================================" $RESET
echo $GREEN  "  " $RESET
echo $BLACK      "=====================================================" $RESET
echo $DARK_GREEN "---------------     End Of Script    ----------------" $RESET
echo $GREEN      "-----------------------------------------------------" $RESET
echo $BLACK      "=====================================================" $RESET