"""
08_rl_portfolio.py
Reinforcement Learning Portfolio Optimization
PPO agent with continuous actions on XGBoost deciles
Reward: Sharpe ratio with transaction cost penalty
Expanding window to prevent lookahead bias
"""

import numpy as np
import pandas as pd
import pickle
import gymnasium as gym
from gymnasium import spaces
from stable_baselines3 import PPO
from stable_baselines3.common.vec_env import DummyVecEnv
from stable_baselines3.common.callbacks import EvalCallback
import warnings
warnings.filterwarnings("ignore")

# -------------------------------------------------------
# 1. LOAD DATA
# -------------------------------------------------------
print("=" * 55)
print("  Reinforcement Learning Portfolio Optimization")
print("=" * 55)

print("\n[1] Loading XGBoost predictions and panel data...")

# Load XGBoost predictions (output of 05_xgboost_portfolio.R)
# Convert RDS to parquet first if needed (see note below)
predictions = pd.read_csv("/home/nordera/nordera/predictions.csv")

print(f"Predictions loaded: {len(predictions):,} rows")
print(f"Period: {predictions['yearmon'].min()} to {predictions['yearmon'].max()}")
print(f"Columns: {list(predictions.columns)}")

# Sort by time
predictions = predictions.sort_values("yearmon").reset_index(drop=True)
months = sorted(predictions["yearmon"].unique())
print(f"Unique months: {len(months)}")

# -------------------------------------------------------
# 2. BUILD MONTHLY DECILE FEATURES AND RETURNS
# -------------------------------------------------------
print("\n[2] Building monthly decile features and returns...")

def build_monthly_data(predictions):
    """
    For each month, compute:
    - Features: mean of each variable within each decile (10 x n_features matrix)
    - Returns: mean ret_lead within each decile (vector of 10)
    """
    feature_cols = [
        "xgb_prob", "signal_opportunistic", "signal_routine",
        "ret_lead"
    ]

    monthly_records = []

    for ym in sorted(predictions["yearmon"].unique()):
        month_data = predictions[predictions["yearmon"] == ym].copy()

        if len(month_data) < 50:
            continue

        # Assign deciles based on xgb_prob
        month_data["decile"] = pd.qcut(
            month_data["xgb_prob"],
            q=10,
            labels=False,
            duplicates="drop"
        )

        # For each decile: mean xgb_prob, mean signal_opp, mean ret_lead
        decile_stats = month_data.groupby("decile").agg(
            mean_prob      = ("xgb_prob",             "mean"),
            mean_sig_opp   = ("signal_opportunistic", "mean"),
            
            mean_ret       = ("ret_lead",              "mean"),
            n_stocks       = ("ret_lead",              "count")
        ).reset_index()

        # Ensure all 10 deciles present
        if len(decile_stats) < 10:
            continue

        monthly_records.append({
            "yearmon":    ym,
            "features":   decile_stats[["mean_prob", "mean_sig_opp"]].values,
            "returns":    decile_stats["mean_ret"].values,
            "n_stocks":   decile_stats["n_stocks"].values
        })

    return monthly_records

monthly_data = build_monthly_data(predictions)
print(f"Monthly records built: {len(monthly_data)}")

# -------------------------------------------------------
# 3. CUSTOM GYM ENVIRONMENT
# -------------------------------------------------------
print("\n[3] Building custom trading environment...")

class InsiderTradingEnv(gym.Env):
    """
    Custom Gym environment for insider trading portfolio optimization.

    State:  features of 10 deciles at time t
            + current portfolio weights (10)
            + last month return (1)
            = 3*10 + 10 + 1 = 41 dimensional state

    Action: continuous weights for each of the 10 deciles
            values in [-1, +1] — negative = short, positive = long
            normalized to sum to zero (long-short constraint)

    Reward: monthly portfolio Sharpe contribution
            - transaction cost penalty
    """

    metadata = {"render_modes": []}

    def __init__(self, monthly_data, transaction_cost=0.001):
        super().__init__()

        self.data             = monthly_data
        self.transaction_cost = transaction_cost  # 10 bps per unit of turnover
        self.n_deciles        = 10
        self.n_features       = 2  # mean_prob, mean_sig_opp, mean_sig_rou

        # State dimension: features (30) + current weights (10) + last return (1)
        self.state_dim = self.n_deciles * self.n_features + self.n_deciles + 1

        # Action space: continuous weights for 10 deciles in [-1, 1]
        self.action_space = spaces.Box(
            low  = -1.0,
            high =  1.0,
            shape = (self.n_deciles,),
            dtype = np.float32
        )

        # Observation space
        self.observation_space = spaces.Box(
            low  = -np.inf,
            high =  np.inf,
            shape = (self.state_dim,),
            dtype = np.float32
        )

        self.reset()

    def reset(self, seed=None, options=None):
        super().reset(seed=seed)
        self.t           = 0
        self.weights     = np.zeros(self.n_deciles, dtype=np.float32)
        self.last_return = 0.0
        self.returns_history = []
        return self._get_obs(), {}

    def _get_obs(self):
        if self.t >= len(self.data):
            features = np.zeros(self.n_deciles * self.n_features, dtype=np.float32)
        else:
            features = self.data[self.t]["features"].flatten().astype(np.float32)

        obs = np.concatenate([
            features,
            self.weights,
            [self.last_return]
        ]).astype(np.float32)
        return obs

    def _normalize_weights(self, action):
        """
        Normalize action to long-short portfolio:
        positive weights = long, negative = short
        Scale so max abs weight = 1
        """
        w = np.array(action, dtype=np.float32)
        max_abs = np.max(np.abs(w))
        if max_abs > 1e-6:
            w = w / max_abs
        return w

    def step(self, action):
        if self.t >= len(self.data):
            return self._get_obs(), 0.0, True, False, {}

        # Normalize weights
        new_weights = self._normalize_weights(action)

        # Transaction costs = sum of absolute weight changes * cost
        turnover     = np.sum(np.abs(new_weights - self.weights))
        tc_penalty   = turnover * self.transaction_cost

        # Portfolio return = weighted average of decile returns
        decile_returns   = self.data[self.t]["returns"].astype(np.float32)
        portfolio_return = np.dot(new_weights, decile_returns) - tc_penalty

        # Update state
        self.weights     = new_weights
        self.last_return = portfolio_return
        self.returns_history.append(portfolio_return)

        # Reward: rolling Sharpe ratio (use last 12 months if available)
        if len(self.returns_history) >= 3:
            hist = np.array(self.returns_history[-12:])
            mean_r = np.mean(hist)
            std_r  = np.std(hist) + 1e-8
            reward = mean_r / std_r  # monthly Sharpe
        else:
            reward = portfolio_return  # use raw return early on

        self.t += 1
        terminated = self.t >= len(self.data)

        return self._get_obs(), float(reward), terminated, False, {}

# -------------------------------------------------------
# 4. EXPANDING WINDOW TRAINING
# -------------------------------------------------------
print("\n[4] Expanding window RL training (2015-2024)...")

all_months   = [d["yearmon"] for d in monthly_data]
all_years    = sorted(set([ym[:4] for ym in all_months]))
first_test   = str(int(min(all_years)) + 5)  # need 5 years of training
test_years   = [y for y in all_years if y >= first_test and y <= "2024"]

print(f"First test year: {first_test}")
print(f"Test years: {', '.join(test_years)}")

rl_monthly_returns = []

for test_yr in test_years:
    print(f"\n--- Test year: {test_yr} | Train: {min(all_years)} - {int(test_yr)-1} ---")

    # Split data
    train_data = [d for d in monthly_data if d["yearmon"][:4] < test_yr]
    test_data  = [d for d in monthly_data if d["yearmon"][:4] == test_yr]

    print(f"  Train months: {len(train_data)} | Test months: {len(test_data)}")

    if len(train_data) < 24 or len(test_data) == 0:
        print("  Skipping — insufficient data")
        continue

    # Create training environment
    train_env = DummyVecEnv([
        lambda td=train_data: InsiderTradingEnv(td, transaction_cost=0.001)
    ])

    # PPO agent
    model = PPO(
        policy          = "MlpPolicy",
        env             = train_env,
        learning_rate   = 3e-4,
        n_steps         = 512,
        batch_size      = 64,
        n_epochs        = 10,
        gamma           = 0.99,
        gae_lambda      = 0.95,
        clip_range      = 0.2,
        ent_coef        = 0.01,       # encourages exploration
        verbose         = 0,
        seed            = 42,
        policy_kwargs   = dict(net_arch=[128, 128, 64])  # 3-layer MLP
    )

    # Train for enough steps to cover training data multiple times
    total_steps = len(train_data) * 500  # 50 passes through data
    model.learn(total_timesteps=total_steps)
    print(f"  Training complete ({total_steps:,} steps)")

    # Evaluate on test data
    test_env = InsiderTradingEnv(test_data, transaction_cost=0.001)
    obs, _   = test_env.reset()

    monthly_rets = []
    for _ in range(len(test_data)):
        action, _ = model.predict(obs, deterministic=True)
        obs, reward, terminated, truncated, info = test_env.step(action)
        monthly_rets.append(test_env.last_return)
        if terminated or truncated:
            break

    # Store results
    for i, d in enumerate(test_data[:len(monthly_rets)]):
        rl_monthly_returns.append({
            "yearmon": d["yearmon"],
            "ret_rl":  monthly_rets[i]
        })

    ann_ret = np.mean(monthly_rets) * 12
    sharpe  = (np.mean(monthly_rets) / (np.std(monthly_rets) + 1e-8)) * np.sqrt(12)
    print(f"  Test year {test_yr}: Ann. return = {ann_ret:+.2%}, Sharpe = {sharpe:.2f}")

# -------------------------------------------------------
# 5. PERFORMANCE SUMMARY
# -------------------------------------------------------
print("\n\n" + "=" * 60)
print("  REINFORCEMENT LEARNING PERFORMANCE SUMMARY")
print("=" * 60)

rl_df   = pd.DataFrame(rl_monthly_returns).sort_values("yearmon")
rl_rets = rl_df["ret_rl"].values

ann_ret  = np.mean(rl_rets) * 12
ann_vol  = np.std(rl_rets)  * np.sqrt(12)
sharpe   = ann_ret / (ann_vol + 1e-8)
hit_rate = np.mean(rl_rets > 0) * 100
wealth   = np.prod(1 + rl_rets)

print(f"  Strategy:         PPO RL (continuous, 10 deciles)")
print(f"  Period:           {rl_df['yearmon'].min()} to {rl_df['yearmon'].max()}")
print(f"  Months:           {len(rl_rets)}")
print(f"  Ann. Return:      {ann_ret:+.2%}")
print(f"  Ann. Volatility:  {ann_vol:.2%}")
print(f"  Sharpe Ratio:     {sharpe:.2f}")
print(f"  Hit Rate:         {hit_rate:.1f}%")
print(f"  $1 → $:           {wealth:.2f}")
print("=" * 60)

# Comparison with other strategies
print("\n  Comparison with previous strategies:")
print(f"  {'Strategy':<25} {'Ann.Ret':>10} {'Sharpe':>8} {'$1→':>8}")
print(f"  {'-'*55}")
print(f"  {'Regression L/S':<25} {'-1.16%':>10} {'-0.18':>8} {'$0.89':>8}")
print(f"  {'XGBoost Top/Bot 20%':<25} {'+25.18%':>10} {'+1.38':>8} {'$6.48':>8}")
print(f"  {'XGBoost Decile 10-1':<25} {'+34.24%':>10} {'+1.58':>8} {'$11.60':>8}")
print(f"  {'RL PPO (continuous)':<25} {ann_ret:>+9.2%} {sharpe:>8.2f} {'${:.2f}'.format(wealth):>8}")

# -------------------------------------------------------
# 6. SAVE RESULTS
# -------------------------------------------------------
results = {
    "monthly_returns": rl_df,
    "ann_return":      ann_ret,
    "sharpe":          sharpe,
    "hit_rate":        hit_rate,
    "wealth":          wealth
}

with open("/home/nordera/nordera/rl_results.pkl", "wb") as f:
    pickle.dump(results, f)

rl_df.to_csv("/home/nordera/nordera/rl_monthly_returns.csv", index=False)

print("\nSaved:")
print("  rl_results.pkl")
print("  rl_monthly_returns.csv")
print("\n=== DONE ===")
