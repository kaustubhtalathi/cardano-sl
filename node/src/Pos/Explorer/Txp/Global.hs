
-- | Explorer's global Txp (expressed as settings).

module Pos.Explorer.Txp.Global
       ( explorerTxpGlobalSettings
       ) where

import           Universum

import qualified Data.HashMap.Strict   as HM

import           Pos.Core              (HeaderHash, headerHash)
import           Pos.DB                (SomeBatchOp (..))
import           Pos.Slotting          (MonadSlots, getSlotStart, getCurrentSlotBlocking)
import           Pos.Txp               (ApplyBlocksSettings (..), TxpBlund,
                                        TxpGlobalRollbackMode, TxpGlobalSettings (..),
                                        applyBlocksWith, blundToAuxNUndo,
                                        genericToilModifierToBatch, runToilAction,
                                        txpGlobalSettings)
import           Pos.Txp.Core          (TxAux, TxUndo)
import           Pos.Util.Chrono       (NE, NewestFirst (..))
import qualified Pos.Util.Modifier     as MM

import qualified Pos.Explorer.DB       as GS
import           Pos.Explorer.Txp.Toil (EGlobalApplyToilMode, ExplorerExtra (..),
                                        eApplyToil, eRollbackToil)


-- | Settings used for global transactions data processing used by explorer.
explorerTxpGlobalSettings :: TxpGlobalSettings
explorerTxpGlobalSettings =
    -- verification is same
    txpGlobalSettings
    { tgsApplyBlocks = applyBlocksWith eApplyBlocksSettings
    , tgsRollbackBlocks = rollbackBlocks
    }

eApplyBlocksSettings
    :: (EGlobalApplyToilMode ctx m, MonadSlots ctx m)
    => ApplyBlocksSettings ExplorerExtra m
eApplyBlocksSettings =
    ApplyBlocksSettings
    { absApplySingle = applyBlund
    , absExtraOperations = extraOps
    }

extraOps :: ExplorerExtra -> SomeBatchOp
extraOps (ExplorerExtra em (HM.toList -> histories) balances) =
    SomeBatchOp $
    map GS.DelTxExtra (MM.deletions em) ++
    map (uncurry GS.AddTxExtra) (MM.insertions em) ++
    map (uncurry GS.UpdateAddrHistory) histories ++
    map (uncurry GS.PutAddrBalance) (MM.insertions balances) ++
    map GS.DelAddrBalance (MM.deletions balances)

applyBlund
    :: (MonadSlots ctx m, EGlobalApplyToilMode ctx m)
    => TxpBlund
    -> m ()
applyBlund blund = do
    -- First get the current @SlotId@ so we can calculate the time.
    -- Then get when that @SlotId@ started and use that as a time for @Tx@.
    mTxTimestamp <- getCurrentSlotBlocking >>= getSlotStart

    uncurry (eApplyToil mTxTimestamp) $ blundToAuxNUndoWHash blund

rollbackBlocks
    :: TxpGlobalRollbackMode ctx m
    => NewestFirst NE TxpBlund -> m SomeBatchOp
rollbackBlocks blunds =
    (genericToilModifierToBatch extraOps) . snd <$>
    runToilAction (mapM (eRollbackToil . blundToAuxNUndo) blunds)

-- Zip block's TxAuxes and also add block hash
blundToAuxNUndoWHash :: TxpBlund -> ([(TxAux, TxUndo)], HeaderHash)
blundToAuxNUndoWHash blund@(blk, _) =
    (blundToAuxNUndo blund, either headerHash (headerHash . fst) blk)
