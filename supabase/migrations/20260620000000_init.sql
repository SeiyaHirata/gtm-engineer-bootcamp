-- ReServe合宿（仮想予約SaaS）スキーマ
-- 設計.md「データモデル」に準拠。INSERTは書かない（データは seed.sql で投入）。
--
-- 親→子のFK順で CREATE する：
--   stores / users（FKなし）
--   → billing_periods（store_id）
--   → reservations（user_id, store_id）
--   → payments（user_id）
--   → checkins（user_id, payment_id）
--
-- id は seq 相当（連番）として扱う。stores.id を seq として使い、
-- seq<=280 で is_setup_done、seq<=198 で is_published が立つ（投入は seed 側）。

-- ============================================================
-- stores（500行）— オンボーディング段のみ
-- 継続は stores では見ない。2/3ヶ月目の継続は billing_periods から数える。
-- ============================================================
CREATE TABLE stores (
  id            int         PRIMARY KEY,                 -- seq相当（1..500）
  name          text        NOT NULL,                    -- 店舗名
  is_setup_done boolean     NOT NULL DEFAULT false,      -- 初期設定完了（seq<=280でtrue／★①）
  is_published  boolean     NOT NULL DEFAULT false,      -- 店舗ページ公開（seq<=198でtrue）
  created_at    timestamptz NOT NULL                     -- 登録＝初月課金の発生日時（JST固定）
);

COMMENT ON TABLE  stores               IS '美容室（供給側）。オンボーディング段（設定完了280・公開198）の正典。継続は見ない';
COMMENT ON COLUMN stores.id            IS '主キー＝seq相当（1..500）。設定完了/公開のフラグはこのseqで切る';
COMMENT ON COLUMN stores.name          IS '店舗名';
COMMENT ON COLUMN stores.is_setup_done IS '初期設定完了フラグ。seq<=280でtrue（★① 56%／通常80%）';
COMMENT ON COLUMN stores.is_published  IS '店舗ページ公開フラグ。seq<=198でtrue（設定完了の71%）';
COMMENT ON COLUMN stores.created_at    IS '登録（＝初月課金）日時。JST固定';

-- ============================================================
-- users（4,800行）— 初回予約を完了した利用者
-- ファネル段ではなく、予約・決済のFK用。
-- ============================================================
CREATE TABLE users (
  id         int         PRIMARY KEY,    -- 利用者ID（1..4800）
  name       text        NOT NULL,       -- 利用者名（仮名可）
  created_at timestamptz NOT NULL        -- 初回予約を作成した日時（JST固定）
);

COMMENT ON TABLE  users            IS '初回予約を完了した利用者（4,800行）。ファネル段ではなく予約のFK用';
COMMENT ON COLUMN users.id         IS '主キー（1..4800）';
COMMENT ON COLUMN users.name       IS '利用者名（仮名可）';
COMMENT ON COLUMN users.created_at IS '初回予約作成日時。JST固定';

-- ============================================================
-- billing_periods（767行）— 月次課金の履歴（継続の正典）
-- 1店舗につき最大3行。month1=1..500 / month2=1..178 / month3=1..89 のみ paid。
-- (store_id, period_month) はユニーク。
-- ============================================================
CREATE TABLE billing_periods (
  id           int         PRIMARY KEY,                         -- 課金履歴ID
  store_id     int         NOT NULL REFERENCES stores (id),     -- 対象店舗
  period_month int         NOT NULL,                            -- 何ヶ月目の課金か（1/2/3）
  amount       int         NOT NULL,                            -- 12,000（全行同一。DISTINCTで単価特定）
  billed_at    timestamptz NOT NULL,                            -- その月の課金日（JST固定）
  status       text        NOT NULL,                            -- paid（成功）/ failed（未払い・解約）
  CONSTRAINT billing_periods_period_month_chk CHECK (period_month IN (1, 2, 3)),
  CONSTRAINT billing_periods_status_chk        CHECK (status IN ('paid', 'failed')),
  CONSTRAINT billing_periods_store_month_uniq  UNIQUE (store_id, period_month)
);

COMMENT ON TABLE  billing_periods              IS '月次課金の履歴（767行）。継続の正典。month1=500/month2=178/month3=89 のみpaid';
COMMENT ON COLUMN billing_periods.id           IS '主キー';
COMMENT ON COLUMN billing_periods.store_id     IS 'stores.id 外部キー';
COMMENT ON COLUMN billing_periods.period_month IS '何ヶ月目の課金か（1=初月／2=2ヶ月目／3=3ヶ月目★②）';
COMMENT ON COLUMN billing_periods.amount       IS '課金額。全行12,000（DISTINCT amount で単価特定）';
COMMENT ON COLUMN billing_periods.billed_at    IS 'その月の課金日。JST固定（30日ごと）';
COMMENT ON COLUMN billing_periods.status       IS 'paid＝課金成功／failed＝未払い・解約';

-- ============================================================
-- reservations（7,425行）
-- 初回予約4,800（confirmed2,160＋cancelled2,640）＋リピート2,625（全confirmed）。
-- confirmed合計4,785／cancelled2,640。全行 postpaid（後払い）。
-- ============================================================
CREATE TABLE reservations (
  id             int         PRIMARY KEY,                       -- 予約ID
  user_id        int         NOT NULL REFERENCES users (id),    -- 予約した利用者
  store_id       int         NOT NULL REFERENCES stores (id),   -- 予約先店舗
  status         text        NOT NULL,                          -- confirmed（来店確定）/ cancelled（★③b）
  payment_timing text        NOT NULL,                          -- 全行 postpaid（後払い）
  created_at     timestamptz NOT NULL,                          -- 予約作成日時（JST固定）
  CONSTRAINT reservations_status_chk         CHECK (status IN ('confirmed', 'cancelled')),
  CONSTRAINT reservations_payment_timing_chk CHECK (payment_timing IN ('postpaid'))
);

COMMENT ON TABLE  reservations                IS '予約（7,425行）。初回4,800（confirmed2,160＋cancelled2,640）＋リピート2,625（全confirmed）';
COMMENT ON COLUMN reservations.id             IS '主キー';
COMMENT ON COLUMN reservations.user_id        IS 'users.id 外部キー（予約した利用者）';
COMMENT ON COLUMN reservations.store_id       IS 'stores.id 外部キー（予約先店舗）';
COMMENT ON COLUMN reservations.status         IS 'confirmed＝来店確定（4,785）／cancelled＝キャンセル（2,640・★③b）';
COMMENT ON COLUMN reservations.payment_timing IS '全行 postpaid（後払い）。③bの構造的原因';
COMMENT ON COLUMN reservations.created_at     IS '予約作成日時。JST固定';

-- ============================================================
-- payments（4,569行・来店時後払い）
-- 初回1,944＋リピート2,625。AVG=4,000 / SUM=18,276,000。
-- ============================================================
CREATE TABLE payments (
  id      int         PRIMARY KEY,                    -- 決済ID
  user_id int         NOT NULL REFERENCES users (id), -- 決済した利用者
  amount  int         NOT NULL,                       -- 決済額（AVG=4,000・合計18,276,000）
  paid_at timestamptz NOT NULL                        -- 来店時の決済日時（JST固定）
);

COMMENT ON TABLE  payments         IS '来店時後払い決済（4,569行）。初回1,944＋リピート2,625。GMVの源泉';
COMMENT ON COLUMN payments.id      IS '主キー';
COMMENT ON COLUMN payments.user_id IS 'users.id 外部キー（HAVING COUNT(*)>=2 でリピーター875を特定）';
COMMENT ON COLUMN payments.amount  IS '決済額。AVG=4,000／SUM=18,276,000（GMV）。手数料はSUM×1%=182,760';
COMMENT ON COLUMN payments.paid_at IS '来店時の決済日時。JST固定';

-- ============================================================
-- checkins（4,569行）— 来店＝決済。payments と1:1対応。
-- ============================================================
CREATE TABLE checkins (
  id          int         PRIMARY KEY,                       -- 来店ID
  user_id     int         NOT NULL REFERENCES users (id),    -- 来店した利用者
  payment_id  int         NOT NULL REFERENCES payments (id), -- 対応する決済（1:1）
  checked_in_at timestamptz NOT NULL,                        -- 来店日時（JST固定）
  CONSTRAINT checkins_payment_uniq UNIQUE (payment_id)       -- payments と1:1を保証
);

COMMENT ON TABLE  checkins               IS '来店（4,569行）。来店＝決済。payments と1:1対応';
COMMENT ON COLUMN checkins.id            IS '主キー';
COMMENT ON COLUMN checkins.user_id       IS 'users.id 外部キー（来店した利用者）';
COMMENT ON COLUMN checkins.payment_id    IS 'payments.id 外部キー。UNIQUE制約で1:1を保証';
COMMENT ON COLUMN checkins.checked_in_at IS '来店日時。JST固定';
