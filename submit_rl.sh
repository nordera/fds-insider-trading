#!/bin/bash
#SBATCH --job-name=rl_insider
#SBATCH --output=/home/nordera/nordera/logs/rl_%j.out
#SBATCH --error=/home/nordera/nordera/logs/rl_%j.err
#SBATCH --time=04:00:00
#SBATCH --mem=64G
#SBATCH --cpus-per-task=16
#SBATCH --partition=mit_normal

module load miniforge
conda activate insider
cd ~/nordera

Rscript 08a_export_predictions.R
python3 08_rl_portfolio.py
