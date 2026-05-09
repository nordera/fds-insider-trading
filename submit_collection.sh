#!/bin/bash
#SBATCH --job-name=insider_collection
#SBATCH --output=/home/nordera/nordera/logs/collection_%j.out
#SBATCH --error=/home/nordera/nordera/logs/collection_%j.err
#SBATCH --time=02:00:00
#SBATCH --mem=16G
#SBATCH --cpus-per-task=8
#SBATCH --partition=mit_normal

source ~/.bashrc
module load miniforge
conda activate insider

cd ~/nordera
python data_collection.py
