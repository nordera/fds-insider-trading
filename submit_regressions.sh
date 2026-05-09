#!/bin/bash
#SBATCH --job-name=xgboost_insider
#SBATCH --output=/home/nordera/nordera/logs/xgboost_%j.out
#SBATCH --error=/home/nordera/nordera/logs/xgboost_%j.err
#SBATCH --time=02:00:00
#SBATCH --mem=64G
#SBATCH --cpus-per-task=16
#SBATCH --partition=mit_normal

module load miniforge
conda activate insider
cd ~/nordera
Rscript 05_xgboost_portfolio.R
