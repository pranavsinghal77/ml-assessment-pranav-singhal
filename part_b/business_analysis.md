# Part B: Business Case Analysis

**Scenario: Promotion Effectiveness at a Fashion Retail Chain**

A fashion retailer runs 50 stores across urban, semi-urban, and rural locations. Every month the marketing team picks one of five promotions to run — Flat Discount, BOGO, Free Gift with Purchase, Category-Specific Offer, and Loyalty Points Bonus. The business wants to figure out which promotion to use in each store each month to get the most items sold.

---

## B1. Problem Formulation

### B1(a) — Machine Learning Problem Formulation

**Target variable:** `items_sold` (a continuous count of units sold per store-month)

**Input features I'd use:**

| Feature | Type | Where it comes from |
|---|---|---|
| `store_id` | Identifier | Store attributes |
| `store_size` | Categorical (small/medium/large) | Store attributes |
| `location_type` | Categorical (urban/semi-urban/rural) | Store attributes |
| `competition_density` | Numerical (1–9) | Store attributes |
| `promotion_type` | Categorical (5 types) | Promotion details |
| `month` | Numerical (1–12) | Calendar |
| `is_weekend` | Binary | Calendar |
| `is_festival` | Binary | Calendar |
| Historical average items sold per store | Numerical | Aggregated from transactions |

This is a **supervised regression problem**. The idea is to train a model that takes store features, the promotion type, and calendar context as inputs and outputs a predicted `items_sold`. At decision time, for each store and each upcoming month you run the model five times — once for each promotion — and pick whichever one gives the highest predicted value.

I chose regression over classification because a classification approach would need labelled data where every store-month already has a "correct" promotion tagged — that kind of ground truth doesn't exist. With regression you only need to observe what actually sold under whatever promotion was run, which is exactly what the transaction history gives you.

---

### B1(b) — Why `items_sold` Rather Than Total Sales Revenue

The main issue with using revenue as the target is that it gets tangled up with pricing mechanics. A Flat Discount promotion automatically cuts the per-item price, so revenue drops even if the same number of items (or more) are sold. BOGO effectively halves the price on every second item, which drags revenue down further. If you train the model to predict revenue, it ends up penalising discount promotions relative to gift or loyalty ones — not because discounts drive less volume, but because they compress the revenue signal. The model would give you systematically misleading recommendations.

`items_sold` directly measures what you actually care about: how many units moved because of the promotion. It's also more stable for comparison — if a store runs BOGO one month and Flat Discount the next, the revenue difference is partly just the different discount levels, not a real demand shift. Volume strips that noise out.

There's a broader principle here too. The target variable should match the thing you're actually trying to optimise, as directly as possible. Using revenue would mean optimising a proxy that diverges from the stated goal (maximise items sold) whenever pricing varies between promotions — which it always does here.

---

### B1(c) — Alternative to a Single Global Model

A single model trained on all 50 stores assumes that the relationship between promotions and sales is the same everywhere. But urban and rural shoppers respond quite differently — BOGO tends to drive much higher volumes in urban stores than rural ones, and that pattern doesn't average out cleanly.

A better approach would be to train **three separate models by location type** — one for urban, one for semi-urban, one for rural. Each model learns the promotion elasticities specific to its customer base. Urban shoppers tend to have higher disposable income and respond strongly to BOGO (it also works well socially — buy one get one is a natural "bring a friend" offer). Rural shoppers often respond better to straightforward flat discounts where the saving is clear and immediate.

The stratified models also avoid the "averaging" problem where the global model's coefficients end up being some blend of urban and rural behaviour — a blend that may not reflect either group accurately. With three models you get predictions that are actually calibrated to each store's context.

Other options would be to add explicit `location_type × promotion_type` interaction features to a single model, or to use a hierarchical model with store-level random effects. Both are valid but add complexity. The stratified approach is simpler and easier to explain to a marketing team.

---

## B2. Data and EDA Strategy

### B2(a) — Joining the Four Tables

The four tables and their key columns:

| Table | Row grain | Key columns |
|---|---|---|
| `transactions` | One row per transaction | `transaction_id`, `store_id`, `date`, `items_sold` |
| `store_attributes` | One row per store | `store_id`, `store_size`, `location_type`, `competition_density` |
| `promotion_details` | One row per store-month | `store_id`, `month`, `year`, `promotion_type` |
| `calendar` | One row per date | `date`, `is_weekend`, `is_festival`, `month`, `year` |

The join sequence I'd use:

```sql
transactions
  LEFT JOIN store_attributes  ON transactions.store_id = store_attributes.store_id
  LEFT JOIN promotion_details ON transactions.store_id = promotion_details.store_id
                              AND MONTH(transactions.date) = promotion_details.month
                              AND YEAR(transactions.date)  = promotion_details.year
  LEFT JOIN calendar          ON transactions.date = calendar.date
```

After joining, the transaction-level data needs to be aggregated up to **store × month** grain before modelling. That means summing `items_sold` and computing derived features like average basket size per month. This gives you one row per store-month, which is the level at which promotion decisions are actually made.

Before doing any of this I'd check referential integrity — making sure every `store_id` in the transactions table has a matching row in store_attributes. I'd also verify that each store only has one active promotion per month in the promotion_details table, and decide how to handle months with no promotion (either model them as a "no promotion" category or exclude them, depending on the business question).

---

### B2(b) — EDA Before Building the Model

**1. Items sold by promotion type (box plot)**

The first thing I'd plot is the distribution of `items_sold` for each promotion. Box plots work well here — they show median, spread, and outliers across the five types. This tells you whether one promotion dominates overall, and whether there's a lot of variance within promotions (which would suggest other factors matter more). If BOGO shows a higher median but also a wider spread, that's a sign it interacts with store or calendar features in ways the model needs to capture.

**2. Promotion × location type heatmap**

A 5×3 mean `items_sold` matrix with promotions on one axis and location types on the other. This is probably the most important EDA step for this dataset because it directly tests the assumption behind stratified modelling (B1c). If the cells look similar across rows, a global model is fine. If they differ a lot — say BOGO shows 320 in urban vs 240 in rural — that's strong evidence for stratification and also suggests interaction terms would help any global model.

**3. Monthly average items sold over time (line plot)**

Plotting the monthly average across all stores over the three years shows seasonal patterns and any year-over-year trend. This matters a lot for the train-test split decision — if there's a December spike every year, you need the test period to include at least one full cycle, and you need to make sure `month` and `is_festival` are in the feature set. If there's a growth trend across years, `year` probably needs to be a feature too.

**4. Correlation of numerical features with items_sold**

A quick correlation table or heatmap for the numerical features (`competition_density`, `is_weekend`, `is_festival`, any store size numeric encoding). This flags which features are worth including and checks for multicollinearity. Multicollinearity matters more if you're using linear regression — Random Forest doesn't care much — but it's still useful context.

**5. Sales by store size (violin plot)**

Do large stores always outsell small stores regardless of promotion type, or does the gap narrow under certain promotions? A violin plot grouped by store_size and coloured by promotion type would show this. If large stores dominate unconditionally, `store_size` will be a very high-importance feature. If promotions close the gap, there may be a useful `store_size × promotion_type` interaction to engineer.

---

### B2(c) — Dealing with 80% No-Promotion Records

If 80% of observations have no active promotion, the model sees far more baseline-condition records than promotion records. Across 5 promotions that's only about 4% representation per promotion type, which makes it hard for the model to learn reliable promotion-specific effects. It will tend to anchor predictions close to baseline and underestimate incremental lift.

A few ways to handle this:

The simplest fix is to train a separate model exclusively on the 20% of records where a promotion was active, treating the "no promotion" records as historical context rather than training examples for the recommendation engine. This is clean because the business question is specifically about *which promotion to run*, not whether to run one at all.

If you do want to keep all records together, oversampling the promoted records (or undersampling the no-promotion records) can help rebalance the training set. SMOTE works for regression too, though it needs to be applied only on the training fold, not before splitting.

Either way, when doing cross-validation, fold assignments should be stratified by promotion type so each fold has representation of all five promotions. Otherwise you can end up with a fold that sees very few examples of, say, Category-Specific Offer and produces misleading validation scores for that promotion.

---

## B3. Model Evaluation and Deployment

### B3(a) — Train-Test Split and Evaluation Metrics

With 36 months × 50 stores = 1,800 store-month records, I'd split as follows:

- **Training set:** Months 1–28 (roughly Years 1–2 plus early Year 3)
- **Test set:** Months 29–36 (the last 8 months, about 22% of data)

Within the training period, hyperparameter tuning should use time-series cross-validation with an expanding window — train on months 1–12, validate on 13–15; then train on 1–15, validate on 16–18; and so on. This preserves the temporal ordering at every stage.

A random split would be wrong here for a few reasons. The most obvious is data leakage — randomly assigning rows could put November 2024 records into the training set and March 2022 records into the test set, which means the model has effectively "seen the future" relative to some test observations. The evaluation metric would look better than it deserves. In practice the model always predicts forward in time, so the evaluation setup needs to replicate that.

For metrics:

**RMSE** is the main one for training — it penalises large prediction errors more heavily, which matters because the model being off by 100 items in a single store-month is a much bigger problem than being off by 20 items consistently.

**MAE** is more useful for communicating results to the marketing team. "Our model is accurate to within ±25 items per store on average" is a statement they can actually act on. MAE is less sensitive to outlier months and gives a cleaner picture of typical error.

**MAPE** (percentage error) rounds things out when stores vary a lot in size — a 30-item error means something very different for a store that averages 100 items vs one that averages 400.

**R²** gives a sense of how much of the total sales variation the model explains, which is useful framing for a management audience.

---

### B3(b) — Feature Importance and Explaining Different Recommendations

**Context:** The model recommends Loyalty Points Bonus for Store 12 in December but Flat Discount for the same store in March.

To understand why, I'd start with global feature importances from the Random Forest — this shows which features matter most across all predictions. Likely candidates are `is_festival`, `month`, and `store_size`.

The more useful tool for explaining individual predictions is SHAP (SHapley Additive exPlanations). SHAP assigns a contribution to each feature for a specific prediction, so you can produce waterfall charts for Store 12 in December and Store 12 in March and compare them directly.

For **December → Loyalty Points Bonus**, the SHAP values would probably show `is_festival = 1` and `month = 12` as strong positive contributors. December customers are visiting with purchase intent — they're buying gifts and treating themselves. Loyalty Points work well here because the customer is already committed to spending; the reward extends the relationship. Competition density also matters: if Store 12 faces low competition in December, retaining customers with loyalty points is a better long-term play than a one-time discount.

For **March → Flat Discount**, the picture reverses. No festival effect, post-holiday budget tightening, and lower inherent foot traffic. In this environment customers are more price-sensitive and a visible flat discount is the strongest trigger to get a casual browser to actually buy. The loyalty programme doesn't offer the same immediate incentive.

To communicate this to the marketing team I'd frame it as: "The model is picking up on why customers visit in each season. In December they're coming in to buy — loyalty points reward that intent and build long-term value. In March the visit is more casual, so a direct price reduction converts more effectively." A SHAP waterfall chart or beeswarm alongside a table of historical promotion performance for Store 12 by month would back this up visually.

---

### B3(c) — Deployment and Monitoring

**Saving the model:**

```python
import joblib

# Save the full pipeline (preprocessor + model together)
joblib.dump(rf_pipeline, 'models/promotion_recommender_v1.pkl')

# Save metadata separately so it's easy to inspect without loading the model
metadata = {
    'trained_on'  : '2022-01-01 to 2024-08-31',
    'model_type'  : 'RandomForestRegressor',
    'features'    : feature_cols,
    'target'      : 'items_sold',
    'test_rmse'   : 42.3,
    'test_mae'    : 31.7,
    'version'     : '1.0'
}
joblib.dump(metadata, 'models/promotion_recommender_v1_metadata.pkl')
```

Saving the full sklearn pipeline (preprocessor + model) together is important — it guarantees that new data goes through exactly the same transformations as the training data, with no manual preprocessing step in between.

**Monthly prediction workflow:**

At the start of each month, build a feature matrix of 50 stores × 5 promotions = **250 rows**. Each row has the store's static attributes, the known calendar features for that month (festivals, how many weekends), and one of the five promotion types. Run the model on all 250 rows, then for each store pick the promotion type with the highest predicted `items_sold`:

```python
model = joblib.load('models/promotion_recommender_v1.pkl')
preds = model.predict(monthly_feature_matrix)

results_df['predicted_items'] = preds
recommendations = (results_df
    .groupby('store_id')
    .apply(lambda g: g.loc[g['predicted_items'].idxmax()])
    .reset_index(drop=True))
```

The recommendations go out to the marketing team with the predicted values for all five promotions shown alongside the top recommendation — not just the winner. That transparency helps them push back if something looks off for a specific store they know well.

**Monitoring:**

Three things to track on a rolling monthly basis:

1. **Prediction accuracy** — after each month completes, compare predicted vs actual `items_sold` for the promoted stores. Track a 3-month rolling MAE. If it degrades more than 20% from the baseline, something has changed.

2. **Feature drift** — compute the Population Stability Index (PSI) for key inputs like `competition_density` and `promotion_type` distribution month-over-month. PSI > 0.2 on any feature is a flag that the input distribution has shifted enough to potentially hurt the model.

3. **New store or promotion types** — if a `store_id` or `promotion_type` value appears that wasn't in the training data, the model will handle it with the `handle_unknown='ignore'` setting in the OHE (it'll just zero out the unknown category) but you'd want to manually review those recommendations rather than blindly trusting them.

**Retraining:**

Quarterly retraining on an expanding window (always include all historical data) handles gradual drift. If a monitoring alert fires sooner, investigate the root cause first — if it's a pricing change or new competitor opening, the feature set may need updating before retraining. When a new model is trained, run it alongside the current one for a month (champion-challenger) and only promote it if the live error metrics are actually better, not just better on the historical test set. All versions go into a model registry (MLflow or equivalent) so previous versions can be rolled back if needed.
