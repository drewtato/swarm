{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

-- |
-- Module      :  Swarm.TUI.Controller
-- Copyright   :  Brent Yorgey
-- Maintainer  :  byorgey@gmail.com
--
-- SPDX-License-Identifier: BSD-3-Clause
--
-- Event handlers for the TUI.
module Swarm.TUI.Controller (
  -- * Event handling
  handleEvent,
  quitGame,

  -- ** Handling 'Frame' events
  runFrameUI,
  runFrame,
  runFrameTicks,
  runGameTickUI,
  runGameTick,
  updateUI,

  -- ** REPL panel
  handleREPLEvent,
  validateREPLForm,
  adjReplHistIndex,
  TimeDir (..),

  -- ** World panel
  handleWorldEvent,
  keyToDir,
  scrollView,
  adjustTPS,

  -- ** Info panel
  handleInfoPanelEvent,
) where

import Brick hiding (Direction)
import Brick.Focus
import Brick.Widgets.Dialog
import Brick.Widgets.Edit (handleEditorEvent)
import Brick.Widgets.List (handleListEvent)
import Brick.Widgets.List qualified as BL
import Control.Carrier.Lift qualified as Fused
import Control.Carrier.State.Lazy qualified as Fused
import Control.Lens
import Control.Lens.Extras (is)
import Control.Monad.Except
import Control.Monad.State
import Data.Bits
import Data.Either (isRight)
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map qualified as M
import Data.Maybe (fromMaybe, isJust, mapMaybe)
import Data.String (fromString)
import Data.Text qualified as T
import Data.Text.IO qualified as T
import Data.Time (getZonedTime)
import Graphics.Vty qualified as V
import Linear
import Swarm.Game.CESK (cancel, emptyStore, initMachine)
import Swarm.Game.Entity hiding (empty)
import Swarm.Game.Robot
import Swarm.Game.ScenarioInfo
import Swarm.Game.State
import Swarm.Game.Step (gameTick)
import Swarm.Game.Value (Value (VUnit), prettyValue)
import Swarm.Game.World qualified as W
import Swarm.Language.Capability (Capability (CMake))
import Swarm.Language.Context
import Swarm.Language.Parse (reservedWords)
import Swarm.Language.Pipeline
import Swarm.Language.Pretty
import Swarm.Language.Requirement qualified as R
import Swarm.Language.Syntax
import Swarm.Language.Typed (Typed (..))
import Swarm.Language.Types
import Swarm.TUI.Inventory.Sorting (cycleSortDirection, cycleSortOrder)
import Swarm.TUI.List
import Swarm.TUI.Model
import Swarm.TUI.View (generateModal)
import Swarm.Util hiding ((<<.=))
import Swarm.Version (NewReleaseFailure (..))
import System.Clock
import Witch (into)

-- | Pattern synonyms to simplify brick event handler
pattern Key :: V.Key -> BrickEvent n e
pattern Key k = VtyEvent (V.EvKey k [])

pattern CharKey, ControlChar, MetaChar :: Char -> BrickEvent n e
pattern CharKey c = VtyEvent (V.EvKey (V.KChar c) [])
pattern ControlChar c = VtyEvent (V.EvKey (V.KChar c) [V.MCtrl])
pattern MetaChar c = VtyEvent (V.EvKey (V.KChar c) [V.MMeta])

pattern ShiftKey :: V.Key -> BrickEvent n e
pattern ShiftKey k = VtyEvent (V.EvKey k [V.MShift])

pattern EscapeKey :: BrickEvent n e
pattern EscapeKey = VtyEvent (V.EvKey V.KEsc [])

pattern FKey :: Int -> BrickEvent n e
pattern FKey c = VtyEvent (V.EvKey (V.KFun c) [])

-- | The top-level event handler for the TUI.
handleEvent :: BrickEvent Name AppEvent -> EventM Name AppState ()
handleEvent = \case
  -- the query for upstream version could finish at any time, so we have to handle it here
  AppEvent (UpstreamVersion ev) -> do
    let logReleaseEvent l e = runtimeState . eventLog %= logEvent l ("Release", -7) (T.pack $ show e)
    case ev of
      Left e@(FailedReleaseQuery _e) -> logReleaseEvent ErrorTrace e
      Left e -> logReleaseEvent Said e
      Right _ -> pure ()
    runtimeState . upstreamRelease .= ev
  e -> do
    s <- get
    if s ^. uiState . uiPlaying
      then handleMainEvent e
      else
        e & case s ^. uiState . uiMenu of
          -- If we reach the NoMenu case when uiPlaying is False, just
          -- quit the app.  We should actually never reach this code (the
          -- quitGame function would have already halted the app).
          NoMenu -> const halt
          MainMenu l -> handleMainMenuEvent l
          NewGameMenu l -> handleNewGameMenuEvent l
          MessagesMenu -> handleMainMessagesEvent
          AboutMenu -> pressAnyKey (MainMenu (mainMenu About))

-- | The event handler for the main menu.
handleMainMenuEvent ::
  BL.List Name MainMenuEntry -> BrickEvent Name AppEvent -> EventM Name AppState ()
handleMainMenuEvent menu = \case
  Key V.KEnter ->
    case snd <$> BL.listSelectedElement menu of
      Nothing -> continueWithoutRedraw
      Just x0 -> case x0 of
        NewGame -> do
          cheat <- use $ uiState . uiCheatMode
          ss <- use $ gameState . scenarios
          uiState . uiMenu .= NewGameMenu (NE.fromList [mkScenarioList cheat ss])
        Tutorial -> do
          -- Set up the menu stack as if the user had chosen "New Game > Tutorials"
          cheat <- use $ uiState . uiCheatMode
          ss <- use $ gameState . scenarios
          let tutorialCollection = getTutorials ss
              topMenu =
                BL.listFindBy
                  ((== "Tutorials") . scenarioItemName)
                  (mkScenarioList cheat ss)
              tutorialMenu = mkScenarioList cheat tutorialCollection
              menuStack = NE.fromList [tutorialMenu, topMenu]
          uiState . uiMenu .= NewGameMenu menuStack

          -- Extract the first tutorial challenge and run it
          let firstTutorial = case scOrder tutorialCollection of
                Just (t : _) -> case M.lookup t (scMap tutorialCollection) of
                  Just (SISingle siPair) -> siPair
                  _ -> error "No first tutorial found!"
                _ -> error "No first tutorial found!"
          startGame firstTutorial Nothing
        Messages -> do
          runtimeState . eventLog . notificationsCount .= 0
          uiState . uiMenu .= MessagesMenu
        About -> uiState . uiMenu .= AboutMenu
        Quit -> halt
  CharKey 'q' -> halt
  ControlChar 'q' -> halt
  VtyEvent ev -> do
    menu' <- nestEventM' menu (handleListEvent ev)
    uiState . uiMenu .= MainMenu menu'
  _ -> continueWithoutRedraw

getTutorials :: ScenarioCollection -> ScenarioCollection
getTutorials sc = case M.lookup "Tutorials" (scMap sc) of
  Just (SICollection _ c) -> c
  _ -> error "No tutorials exist!"

-- | If we are in a New Game menu, advance the menu to the next item in order.
advanceMenu :: Menu -> Menu
advanceMenu = _NewGameMenu . ix 0 %~ BL.listMoveDown

handleMainMessagesEvent :: BrickEvent Name AppEvent -> EventM Name AppState ()
handleMainMessagesEvent = \case
  Key V.KEsc -> returnToMainMenu
  CharKey 'q' -> returnToMainMenu
  ControlChar 'q' -> returnToMainMenu
  _ -> return ()
 where
  returnToMainMenu = uiState . uiMenu .= MainMenu (mainMenu Messages)

handleNewGameMenuEvent :: NonEmpty (BL.List Name ScenarioItem) -> BrickEvent Name AppEvent -> EventM Name AppState ()
handleNewGameMenuEvent scenarioStack@(curMenu :| rest) = \case
  Key V.KEnter ->
    case snd <$> BL.listSelectedElement curMenu of
      Nothing -> continueWithoutRedraw
      Just (SISingle siPair) -> startGame siPair Nothing
      Just (SICollection _ c) -> do
        cheat <- use $ uiState . uiCheatMode
        uiState . uiMenu .= NewGameMenu (NE.cons (mkScenarioList cheat c) scenarioStack)
  Key V.KEsc -> exitNewGameMenu scenarioStack
  CharKey 'q' -> exitNewGameMenu scenarioStack
  ControlChar 'q' -> halt
  VtyEvent ev -> do
    menu' <- nestEventM' curMenu (handleListEvent ev)
    uiState . uiMenu .= NewGameMenu (menu' :| rest)
  _ -> continueWithoutRedraw

exitNewGameMenu :: NonEmpty (BL.List Name ScenarioItem) -> EventM Name AppState ()
exitNewGameMenu stk = do
  uiState . uiMenu
    .= case snd (NE.uncons stk) of
      Nothing -> MainMenu (mainMenu NewGame)
      Just stk' -> NewGameMenu stk'

pressAnyKey :: Menu -> BrickEvent Name AppEvent -> EventM Name AppState ()
pressAnyKey m (VtyEvent (V.EvKey _ _)) = uiState . uiMenu .= m
pressAnyKey _ _ = continueWithoutRedraw

-- | The top-level event handler while we are running the game itself.
handleMainEvent :: BrickEvent Name AppEvent -> EventM Name AppState ()
handleMainEvent ev = do
  s <- get
  mt <- preuse $ uiState . uiModal . _Just . modalType
  let isRunning = maybe True isRunningModal mt
  case ev of
    AppEvent Frame
      | s ^. gameState . paused -> continueWithoutRedraw
      | otherwise -> runFrameUI
    -- ctrl-q works everywhere
    ControlChar 'q' ->
      case s ^. gameState . winCondition of
        Won _ -> toggleModal WinModal
        _ -> toggleModal QuitModal
    VtyEvent (V.EvResize _ _) -> invalidateCacheEntry WorldCache
    Key V.KEsc
      | isJust (s ^. uiState . uiError) -> uiState . uiError .= Nothing
      | Just m <- s ^. uiState . uiModal -> do
        safeAutoUnpause
        uiState . uiModal .= Nothing
        -- message modal is not autopaused, so update notifications when leaving it
        when (m ^. modalType == MessagesModal) $ do
          gameState . lastSeenMessageTime .= s ^. gameState . ticks
    FKey 1 -> toggleModal HelpModal
    FKey 2 -> toggleModal RobotsModal
    FKey 3 | not (null (s ^. gameState . availableRecipes . notificationsContent)) -> do
      toggleModal RecipesModal
      gameState . availableRecipes . notificationsCount .= 0
    FKey 4 | not (null (s ^. gameState . availableCommands . notificationsContent)) -> do
      toggleModal CommandsModal
      gameState . availableCommands . notificationsCount .= 0
    FKey 5 | not (null (s ^. gameState . messageNotifications . notificationsContent)) -> do
      toggleModal MessagesModal
      gameState . lastSeenMessageTime .= s ^. gameState . ticks
    ControlChar 'g' -> case s ^. uiState . uiGoal of
      Just g | g /= [] -> toggleModal (GoalModal g)
      _ -> continueWithoutRedraw
    MetaChar 'h' -> do
      t <- liftIO $ getTime Monotonic
      h <- use $ uiState . uiHideRobotsUntil
      if h >= t
        then -- ignore repeated keypresses
          continueWithoutRedraw
        else -- hide for two seconds
        do
          uiState . uiHideRobotsUntil .= t + TimeSpec 2 0
          invalidateCacheEntry WorldCache
    -- pausing and stepping
    ControlChar 'p' | isRunning -> safeTogglePause
    ControlChar 'o' | isRunning -> do
      gameState . runStatus .= ManualPause
      runGameTickUI
    -- speed controls
    ControlChar 'x' | isRunning -> modify $ adjustTPS (+)
    ControlChar 'z' | isRunning -> modify $ adjustTPS (-)
    -- special keys that work on all panels
    MetaChar 'w' -> setFocus WorldPanel
    MetaChar 'e' -> setFocus RobotPanel
    MetaChar '`' -> setFocus REPLPanel
    MetaChar 't' -> setFocus InfoPanel
    -- pass keys on to modal event handler if a modal is open
    VtyEvent vev
      | isJust (s ^. uiState . uiModal) -> handleModalEvent vev
    -- toggle creative mode if in "cheat mode"
    ControlChar 'v'
      | s ^. uiState . uiCheatMode -> gameState . creativeMode %= not
    MouseDown n _ _ mouseLoc ->
      case n of
        WorldPanel -> do
          mouseCoordsM <- Brick.zoom gameState (mouseLocToWorldCoords mouseLoc)
          uiState . uiWorldCursor .= mouseCoordsM
        REPLInput -> do
          setFocus REPLPanel
          handleREPLEvent ev
        _ -> continueWithoutRedraw
    MouseUp n _ _mouseLoc -> do
      case n of
        InventoryListItem pos -> uiState . uiInventory . traverse . _2 %= BL.listMoveTo pos
        _ -> return ()
      setFocus $ case n of
        -- Adapt click event origin to their right panel.
        -- For the REPL and the World view, using 'Brick.Widgets.Core.clickable' correctly set the origin.
        -- However this does not seems to work for the robot and info panel.
        -- Thus we force the destination focus here.
        InventoryList -> RobotPanel
        InventoryListItem _ -> RobotPanel
        InfoViewport -> InfoPanel
        _ -> n
    -- dispatch any other events to the focused panel handler
    _ev -> do
      fring <- use $ uiState . uiFocusRing
      case focusGetCurrent fring of
        Just REPLPanel -> handleREPLEvent ev
        Just WorldPanel -> handleWorldEvent ev
        Just RobotPanel -> handleRobotPanelEvent ev
        Just InfoPanel -> handleInfoPanelEvent infoScroll ev
        _ -> continueWithoutRedraw

mouseLocToWorldCoords :: Brick.Location -> EventM Name GameState (Maybe W.Coords)
mouseLocToWorldCoords (Brick.Location mouseLoc) = do
  mext <- lookupExtent WorldExtent
  case mext of
    Nothing -> pure Nothing
    Just ext -> do
      region <- gets $ flip viewingRegion (bimap fromIntegral fromIntegral (extentSize ext))
      let regionStart = W.unCoords (fst region)
          mouseLoc' = bimap fromIntegral fromIntegral mouseLoc
          mx = snd mouseLoc' + fst regionStart
          my = fst mouseLoc' + snd regionStart
       in pure . Just $ W.Coords (mx, my)

setFocus :: Name -> EventM Name AppState ()
setFocus name = uiState . uiFocusRing %= focusSetCurrent name

-- | Set the game to Running if it was (auto) paused otherwise to paused.
--
-- Also resets the last frame time to now. If we are pausing, it
-- doesn't matter; if we are unpausing, this is critical to
-- ensure the next frame doesn't think it has to catch up from
-- whenever the game was paused!
safeTogglePause :: EventM Name AppState ()
safeTogglePause = do
  curTime <- liftIO $ getTime Monotonic
  uiState . lastFrameTime .= curTime
  gameState . runStatus %= toggleRunStatus

-- | Only unpause the game if leaving autopaused modal.
--
-- Note that the game could have been paused before opening
-- the modal, in that case, leave the game paused.
safeAutoUnpause :: EventM Name AppState ()
safeAutoUnpause = do
  runs <- use $ gameState . runStatus
  when (runs == AutoPause) safeTogglePause

toggleModal :: ModalType -> EventM Name AppState ()
toggleModal mt = do
  modal <- use $ uiState . uiModal
  case modal of
    Nothing -> do
      newModal <- gets $ flip generateModal mt
      ensurePause
      uiState . uiModal ?= newModal
    Just _ -> uiState . uiModal .= Nothing >> safeAutoUnpause
 where
  -- Set the game to AutoPause if needed
  ensurePause = do
    pause <- use $ gameState . paused
    unless (pause || isRunningModal mt) $ do
      gameState . runStatus .= AutoPause

-- | The running modals do not autopause the game.
isRunningModal :: ModalType -> Bool
isRunningModal mt = mt `elem` [RobotsModal, MessagesModal]

handleModalEvent :: V.Event -> EventM Name AppState ()
handleModalEvent = \case
  V.EvKey V.KEnter [] -> do
    mdialog <- preuse $ uiState . uiModal . _Just . modalDialog
    toggleModal QuitModal
    case dialogSelection <$> mdialog of
      Just (Just QuitButton) -> quitGame
      Just (Just KeepPlayingButton) -> toggleModal KeepPlayingModal
      Just (Just (StartOverButton currentSeed siPair)) -> restartGame currentSeed siPair
      Just (Just (NextButton siPair)) -> saveScenarioInfoOnQuit >> startGame siPair Nothing
      _ -> return ()
  ev -> do
    Brick.zoom (uiState . uiModal . _Just . modalDialog) (handleDialogEvent ev)
    modal <- preuse $ uiState . uiModal . _Just . modalType
    case modal of
      Just _ -> handleInfoPanelEvent modalScroll (VtyEvent ev)
      _ -> return ()

-- | Write the @ScenarioInfo@ out to disk when exiting a game.
saveScenarioInfoOnQuit :: (MonadIO m, MonadState AppState m) => m ()
saveScenarioInfoOnQuit = do
  -- Don't save progress if we are in cheat mode
  cheat <- use $ uiState . uiCheatMode
  unless cheat $ do
    -- the path should be normalized and good to search in scenario collection
    mp' <- use $ gameState . currentScenarioPath
    case mp' of
      Nothing -> return ()
      Just p' -> do
        gs <- use $ gameState . scenarios
        p <- liftIO $ normalizeScenarioPath gs p'
        t <- liftIO getZonedTime
        won <- isJust <$> preuse (gameState . winCondition . _Won)
        ts <- use $ gameState . ticks
        let currentScenarioInfo :: Traversal' AppState ScenarioInfo
            currentScenarioInfo = gameState . scenarios . scenarioItemByPath p . _SISingle . _2
        currentScenarioInfo %= updateScenarioInfoOnQuit t ts won
        status <- preuse currentScenarioInfo
        case status of
          Nothing -> return ()
          Just si -> liftIO $ saveScenarioInfo p si

        -- See what scenario is currently focused in the menu.  Depending on how the
        -- previous scenario ended (via quit vs. via win), it might be the same as
        -- currentScenarioPath or it might be different.
        curPath <- preuse $ uiState . uiMenu . _NewGameMenu . ix 0 . BL.listSelectedElementL . _SISingle . _2 . scenarioPath
        -- Now rebuild the NewGameMenu so it gets the updated ScenarioInfo,
        -- being sure to preserve the same focused scenario.
        sc <- use $ gameState . scenarios
        forM_ (mkNewGameMenu cheat sc (fromMaybe p curPath)) (uiState . uiMenu .=)

-- | Quit a game.
--
-- * writes out the updated REPL history to a @.swarm_history@ file
-- * saves current scenario status (InProgress/Completed)
-- * returns to the previous menu
quitGame :: EventM Name AppState ()
quitGame = do
  history <- use $ uiState . uiREPL . replHistory
  let hist = mapMaybe getREPLEntry $ getLatestREPLHistoryItems maxBound history
  liftIO $ (`T.appendFile` T.unlines hist) =<< getSwarmHistoryPath True
  saveScenarioInfoOnQuit
  menu <- use $ uiState . uiMenu
  case menu of
    NoMenu -> halt
    _ -> uiState . uiPlaying .= False

------------------------------------------------------------
-- Handling Frame events
------------------------------------------------------------

-- | Run the game for a single /frame/ (/i.e./ screen redraw), then
--   update the UI.  Depending on how long it is taking to draw each
--   frame, and how many ticks per second we are trying to achieve,
--   this may involve stepping the game any number of ticks (including
--   zero).
runFrameUI :: EventM Name AppState ()
runFrameUI = do
  runFrame
  redraw <- updateUI
  unless redraw continueWithoutRedraw

-- | Run the game for a single frame, without updating the UI.
runFrame :: EventM Name AppState ()
runFrame = do
  -- Reset the needsRedraw flag.  While procssing the frame and stepping the robots,
  -- the flag will get set to true if anything changes that requires redrawing the
  -- world (e.g. a robot moving or disappearing).
  gameState . needsRedraw .= False

  -- The logic here is taken from https://gafferongames.com/post/fix_your_timestep/ .

  -- Find out how long the previous frame took, by subtracting the
  -- previous time from the current time.
  prevTime <- use (uiState . lastFrameTime)
  curTime <- liftIO $ getTime Monotonic
  let frameTime = diffTimeSpec curTime prevTime

  -- Remember now as the new previous time.
  uiState . lastFrameTime .= curTime

  -- We now have some additional accumulated time to play with.  The
  -- idea is to now "catch up" by doing as many ticks as are supposed
  -- to fit in the accumulated time.  Some accumulated time may be
  -- left over, but it will roll over to the next frame.  This way we
  -- deal smoothly with things like a variable frame rate, the frame
  -- rate not being a nice multiple of the desired ticks per second,
  -- etc.
  uiState . accumulatedTime += frameTime

  -- Figure out how many ticks per second we're supposed to do,
  -- and compute the timestep `dt` for a single tick.
  lgTPS <- use (uiState . lgTicksPerSecond)
  let oneSecond = 1_000_000_000 -- one second = 10^9 nanoseconds
      dt
        | lgTPS >= 0 = oneSecond `div` (1 `shiftL` lgTPS)
        | otherwise = oneSecond * (1 `shiftL` abs lgTPS)

  -- Update TPS/FPS counters every second
  infoUpdateTime <- use (uiState . lastInfoTime)
  let updateTime = toNanoSecs $ diffTimeSpec curTime infoUpdateTime
  when (updateTime >= oneSecond) $ do
    -- Wait for at least one second to have elapsed
    when (infoUpdateTime /= 0) $ do
      -- set how much frame got processed per second
      frames <- use (uiState . frameCount)
      uiState . uiFPS .= fromIntegral (frames * fromInteger oneSecond) / fromIntegral updateTime

      -- set how much ticks got processed per frame
      uiTicks <- use (uiState . tickCount)
      uiState . uiTPF .= fromIntegral uiTicks / fromIntegral frames

      -- ensure this frame gets drawn
      gameState . needsRedraw .= True

    -- Reset the counter and wait another seconds for the next update
    uiState . tickCount .= 0
    uiState . frameCount .= 0
    uiState . lastInfoTime .= curTime

  -- Increment the frame count
  uiState . frameCount += 1

  -- Now do as many ticks as we need to catch up.
  uiState . frameTickCount .= 0
  runFrameTicks (fromNanoSecs dt)

ticksPerFrameCap :: Int
ticksPerFrameCap = 30

-- | Do zero or more ticks, with each tick notionally taking the given
--   timestep, until we have used up all available accumulated time,
--   OR until we have hit the cap on ticks per frame, whichever comes
--   first.
runFrameTicks :: TimeSpec -> EventM Name AppState ()
runFrameTicks dt = do
  a <- use (uiState . accumulatedTime)
  t <- use (uiState . frameTickCount)

  -- Is there still time left?  Or have we hit the cap on ticks per frame?
  when (a >= dt && t < ticksPerFrameCap) $ do
    -- If so, do a tick, count it, subtract dt from the accumulated time,
    -- and loop!
    runGameTick
    uiState . tickCount += 1
    uiState . frameTickCount += 1
    uiState . accumulatedTime -= dt
    runFrameTicks dt

-- | Run the game for a single tick, and update the UI.
runGameTickUI :: EventM Name AppState ()
runGameTickUI = runGameTick >> void updateUI

-- | Modifies the game state using a fused-effect state action.
zoomGameState :: (MonadState AppState m, MonadIO m) => Fused.StateC GameState (Fused.LiftC IO) a -> m ()
zoomGameState f = do
  gs <- use gameState
  gs' <- liftIO (Fused.runM (Fused.execState gs f))
  gameState .= gs'

-- | Run the game for a single tick (/without/ updating the UI).
--   Every robot is given a certain amount of maximum computation to
--   perform a single world action (like moving, turning, grabbing,
--   etc.).
runGameTick :: EventM Name AppState ()
runGameTick = zoomGameState gameTick

-- | Update the UI.  This function is used after running the
--   game for some number of ticks.
updateUI :: EventM Name AppState Bool
updateUI = do
  loadVisibleRegion

  -- If the game state indicates a redraw is needed, invalidate the
  -- world cache so it will be redrawn.
  g <- use gameState
  when (g ^. needsRedraw) $ invalidateCacheEntry WorldCache

  -- Check if the inventory list needs to be updated.
  listRobotHash <- fmap fst <$> use (uiState . uiInventory)
  -- The hash of the robot whose inventory is currently displayed (if any)

  fr <- use (gameState . to focusedRobot)
  let focusedRobotHash = view inventoryHash <$> fr
  -- The hash of the focused robot (if any)

  shouldUpdate <- use (uiState . uiInventoryShouldUpdate)
  -- If the hashes don't match (either because which robot (or
  -- whether any robot) is focused changed, or the focused robot's
  -- inventory changed), regenerate the list.
  inventoryUpdated <-
    if listRobotHash /= focusedRobotHash || shouldUpdate
      then do
        Brick.zoom uiState $ populateInventoryList fr
        (uiState . uiInventoryShouldUpdate) .= False
        pure True
      else pure False

  -- Now check if the base finished running a program entered at the REPL.
  replUpdated <- case g ^. replStatus of
    -- It did, and the result was the unit value.  Just reset replStatus.
    REPLWorking (Typed (Just VUnit) typ reqs) -> do
      gameState . replStatus .= REPLDone (Just $ Typed VUnit typ reqs)
      pure True

    -- It did, and returned some other value.  Pretty-print the
    -- result as a REPL output, with its type, and reset the replStatus.
    REPLWorking (Typed (Just v) pty reqs) -> do
      let finalType = stripCmd pty
      let val = Typed v finalType reqs
      itIx <- use (gameState . replNextValueIndex)
      let itName = fromString $ "it" ++ show itIx
      let out = T.intercalate " " [itName, ":", prettyText finalType, "=", into (prettyValue v)]
      uiState . uiREPL . replHistory %= addREPLItem (REPLOutput out)
      gameState . replStatus .= REPLDone (Just val)
      gameState . baseRobot . robotContext . at itName .= Just val
      gameState . replNextValueIndex %= (+ 1)
      pure True

    -- Otherwise, do nothing.
    _ -> pure False

  -- If the focused robot's log has been updated and the UI focus
  -- isn't currently on the inventory or info panels, attempt to
  -- automatically switch to the logger and scroll all the way down so
  -- the new message can be seen.
  uiState . uiScrollToEnd .= False
  logUpdated <- do
    -- If the inventory or info panels are currently focused, it would
    -- be rude to update them right under the user's nose, so consider
    -- them "sticky".  They will be updated as soon as the player moves
    -- the focus away.
    fring <- use $ uiState . uiFocusRing
    let sticky = focusGetCurrent fring `elem` [Just RobotPanel, Just InfoPanel]

    -- Check if the robot log was updated and we are allowed to change
    -- the inventory+info panels.
    case maybe False (view robotLogUpdated) fr && not sticky of
      False -> pure False
      True -> do
        -- Reset the log updated flag
        zoomGameState clearFocusedRobotLogUpdated

        -- Find and focus an installed "logger" device in the inventory list.
        let isLogger (InstalledEntry e) = e ^. entityName == "logger"
            isLogger _ = False
            focusLogger = BL.listFindBy isLogger

        uiState . uiInventory . _Just . _2 %= focusLogger

        -- Now inform the UI that it should scroll the info panel to
        -- the very end.
        uiState . uiScrollToEnd .= True
        pure True

  -- Decide whether the info panel has more content scrolled off the
  -- top and/or bottom, so we can draw some indicators to show it if
  -- so.  Note, because we only know the update size and position of
  -- the viewport *after* it has been rendered, this means the top and
  -- bottom indicators will only be updated one frame *after* the info
  -- panel updates, but this isn't really that big of deal.
  infoPanelUpdated <- do
    mvp <- lookupViewport InfoViewport
    case mvp of
      Nothing -> return False
      Just vp -> do
        let topMore = (vp ^. vpTop) > 0
            botMore = (vp ^. vpTop + snd (vp ^. vpSize)) < snd (vp ^. vpContentSize)
        oldTopMore <- uiState . uiMoreInfoTop <<.= topMore
        oldBotMore <- uiState . uiMoreInfoBot <<.= botMore
        return $ oldTopMore /= topMore || oldBotMore /= botMore

  -- Decide whether we need to update the current goal text, and pop
  -- up a modal dialog.
  curGoal <- use (uiState . uiGoal)
  newGoal <-
    preuse (gameState . winCondition . _WinConditions . _NonEmpty . _1 . objectiveGoal)

  let goalUpdated = curGoal /= newGoal
  when goalUpdated $ do
    uiState . uiGoal .= newGoal
    case newGoal of
      Just goal | goal /= [] -> do
        toggleModal (GoalModal goal)
      _ -> return ()

  -- Decide whether to show a pop-up modal congratulating the user on
  -- successfully completing the current challenge.
  winModalUpdated <- do
    w <- use (gameState . winCondition)
    case w of
      Won False -> do
        gameState . winCondition .= Won True
        toggleModal WinModal
        uiState . uiMenu %= advanceMenu
        return True
      _ -> return False

  let redraw = g ^. needsRedraw || inventoryUpdated || replUpdated || logUpdated || infoPanelUpdated || goalUpdated || winModalUpdated
  pure redraw

-- | Make sure all tiles covering the visible part of the world are
--   loaded.
loadVisibleRegion :: EventM Name AppState ()
loadVisibleRegion = do
  mext <- lookupExtent WorldExtent
  case mext of
    Nothing -> return ()
    Just (Extent _ _ size) -> do
      gs <- use gameState
      gameState . world %= W.loadRegion (viewingRegion gs (over both fromIntegral size))

-- | Strips top-level `cmd` from type (in case of REPL evaluation),
--   and returns a boolean to indicate if it happened
stripCmd :: Polytype -> Polytype
stripCmd (Forall xs (TyCmd ty)) = Forall xs ty
stripCmd pty = pty

------------------------------------------------------------
-- REPL events
------------------------------------------------------------

-- | Set the REPLForm to the given value, resetting type error checks to Nothing
--   and removing uiError.
resetREPL :: T.Text -> REPLPrompt -> UIState -> UIState
resetREPL t r ui =
  ui
    & uiREPL . replPromptText .~ t
    & uiREPL . replPromptType .~ r
    & uiError .~ Nothing

-- | Handle a user input event for the REPL.
handleREPLEvent :: BrickEvent Name AppEvent -> EventM Name AppState ()
handleREPLEvent x = do
  s <- get
  let repl = s ^. uiState . uiREPL
      controlMode = repl ^. replControlMode
      uinput = repl ^. replPromptText
  case x of
    MetaChar 'p' ->
      onlyCreative $ do
        if T.null uinput
          then uiState . uiREPL . replControlMode %= cycleEnum
          else uiState . uiError ?= "Please clear the REPL first."
    _ -> case controlMode of
      Typing -> handleREPLEventTyping x
      Piloting -> handleREPLEventPiloting x

-- | Handle a user "piloting" input event for the REPL.
handleREPLEventPiloting :: BrickEvent Name AppEvent -> EventM Name AppState ()
handleREPLEventPiloting x = case x of
  Key V.KUp -> inputCmd "move"
  Key V.KDown -> inputCmd "turn back"
  Key V.KLeft -> inputCmd "turn left"
  Key V.KRight -> inputCmd "turn right"
  ShiftKey V.KUp -> inputCmd "turn north"
  ShiftKey V.KDown -> inputCmd "turn south"
  ShiftKey V.KLeft -> inputCmd "turn west"
  ShiftKey V.KRight -> inputCmd "turn east"
  Key V.KDel -> inputCmd "selfdestruct"
  CharKey 'g' -> inputCmd "grab"
  CharKey 'h' -> inputCmd "harvest"
  CharKey 'd' -> inputCmd "drill forward"
  CharKey 's' -> inputCmd "scan forward"
  CharKey 'b' -> inputCmd "blocked"
  CharKey 'u' -> inputCmd "upload base"
  _ -> inputCmd "noop"
 where
  inputCmd cmdText = do
    uiState . uiREPL %= setCmd (cmdText <> ";")
    modify validateREPLForm
    handleREPLEventTyping $ Key V.KEnter

  setCmd nt repl =
    repl
      & replPromptText .~ nt
      & replPromptType .~ CmdPrompt []

-- | Handle a user input event for the REPL.
handleREPLEventTyping :: BrickEvent Name AppEvent -> EventM Name AppState ()
handleREPLEventTyping = \case
  ControlChar 'c' -> do
    gameState . baseRobot . machine %= cancel
    uiState . uiREPL . replPromptType .= CmdPrompt []
    uiState . uiREPL . replPromptText .= ""
  Key V.KEnter -> do
    s <- get
    let topCtx = topContext s
        repl = s ^. uiState . uiREPL
        uinput = repl ^. replPromptText

        -- The player typed something at the REPL and hit Enter; this
        -- function takes the resulting ProcessedTerm (if the REPL
        -- input is valid) and sets up the base robot to run it.
        startBaseProgram t@(ProcessedTerm _ (Module ty _) reqs reqCtx) =
          -- Set the REPL status to Working
          (gameState . replStatus .~ REPLWorking (Typed Nothing ty reqs))
            -- The `reqCtx` maps names of variables defined in the
            -- term (by `def` statements) to their requirements.
            -- E.g. if we had `def m = move end`, the reqCtx would
            -- record the fact that `m` needs the `move` capability.
            -- We simply dump the entire `reqCtx` into the robot's
            -- context, so we can look up requirements if we later
            -- need to requirements-check an argument to `build` or
            -- `reprogram` at runtime.  See the discussion at
            -- https://github.com/swarm-game/swarm/pull/827 for more
            -- details.
            . (gameState . baseRobot . robotContext . defReqs .~ reqCtx)
            -- Set up the robot's CESK machine to evaluate/execute the
            -- given term, being sure to initialize the CESK machine
            -- environment and store from the top-level context.
            . (gameState . baseRobot . machine .~ initMachine t (topCtx ^. defVals) (topCtx ^. defStore))
            -- Finally, be sure to activate the base robot.
            . (gameState %~ execState (activateRobot 0))

    if not $ s ^. gameState . replWorking
      then case repl ^. replPromptType of
        CmdPrompt _ ->
          case processTerm' (topCtx ^. defTypes) (topCtx ^. defReqs) uinput of
            Right mt -> do
              uiState %= resetREPL "" (CmdPrompt [])
              uiState . uiREPL . replHistory %= addREPLItem (REPLEntry uinput)
              modify $ maybe id startBaseProgram mt
            Left err -> uiState . uiError ?= err
        SearchPrompt hist ->
          case lastEntry uinput hist of
            Nothing -> uiState %= resetREPL "" (CmdPrompt [])
            Just found
              | T.null uinput -> uiState %= resetREPL "" (CmdPrompt [])
              | otherwise -> do
                uiState %= resetREPL found (CmdPrompt [])
                modify validateREPLForm
      else continueWithoutRedraw
  Key V.KUp -> modify $ adjReplHistIndex Older
  Key V.KDown -> modify $ adjReplHistIndex Newer
  ControlChar 'r' -> do
    s <- get
    let uinput = s ^. uiState . uiREPL . replPromptText
    case s ^. uiState . uiREPL . replPromptType of
      CmdPrompt _ -> uiState . uiREPL . replPromptType .= SearchPrompt (s ^. uiState . uiREPL . replHistory)
      SearchPrompt rh -> case lastEntry uinput rh of
        Nothing -> pure ()
        Just found -> uiState . uiREPL . replPromptType .= SearchPrompt (removeEntry found rh)
  CharKey '\t' -> do
    s <- get
    let names = s ^.. gameState . baseRobot . robotContext . defTypes . to assocs . traverse . _1
    uiState . uiREPL %= tabComplete names (s ^. gameState . entityMap)
    modify validateREPLForm
  EscapeKey -> do
    formSt <- use $ uiState . uiREPL . replPromptType
    case formSt of
      CmdPrompt {} -> continueWithoutRedraw
      SearchPrompt _ ->
        uiState %= resetREPL "" (CmdPrompt [])
  ControlChar 'd' -> do
    text <- use $ uiState . uiREPL . replPromptText
    if text == T.empty
      then toggleModal QuitModal
      else continueWithoutRedraw
  -- finally if none match pass the event to the editor
  ev -> do
    Brick.zoom (uiState . uiREPL . replPromptEditor) (handleEditorEvent ev)
    uiState . uiREPL . replPromptType %= \case
      CmdPrompt _ -> CmdPrompt [] -- reset completions on any event passed to editor
      SearchPrompt a -> SearchPrompt a
    modify validateREPLForm

data CompletionType
  = FunctionName
  | EntityName
  deriving (Eq)

-- | Try to complete the last word in a partially-entered REPL prompt using
--   reserved words and names in scope (in the case of function names) or
--   entity names (in the case of string literals).
tabComplete :: [Var] -> EntityMap -> REPLState -> REPLState
tabComplete names em repl = case repl ^. replPromptType of
  SearchPrompt _ -> repl
  CmdPrompt mms
    -- Case 1: If completion candidates have already been
    -- populated via case (3), cycle through them.
    -- Note that tabbing through the candidates *does* update the value
    -- of "t", which one might think would narrow the candidate list
    -- to only that match and therefore halt the cycling.
    -- However, the candidate list only gets recomputed (repopulated)
    -- if the user subsequently presses a non-Tab key. Thus the current
    -- value of "t" is ignored for all Tab presses subsequent to the
    -- first.
    | (m : ms) <- mms -> setCmd (replacementFunc m) (ms ++ [m])
    -- Case 2: Require at least one letter to be typed in order to offer completions for
    -- function names.
    -- We allow suggestions for Entity Name strings without anything having been typed.
    | T.null lastWord && completionType == FunctionName -> setCmd t []
    -- Case 3: Typing another character in the REPL clears the completion candidates from
    -- the CmdPrompt, so when Tab is pressed again, this case then gets executed and
    -- repopulates them.
    | otherwise -> case candidateMatches of
      [] -> setCmd t []
      [m] -> setCmd (completeWith m) []
      -- Perform completion with the first candidate, then populate the list
      -- of all candidates with the current completion moved to the back
      -- of the queue.
      (m : ms) -> setCmd (completeWith m) (ms ++ [m])
 where
  -- checks the "parity" of the number of quotes. If odd, then there is an open quote.
  hasOpenQuotes = (== 1) . (`mod` 2) . T.count "\""

  completionType =
    if hasOpenQuotes t
      then EntityName
      else FunctionName

  replacementFunc = T.append $ T.dropWhileEnd replacementBoundaryPredicate t
  completeWith m = T.append t $ T.drop (T.length lastWord) m
  lastWord = T.takeWhileEnd replacementBoundaryPredicate t
  candidateMatches = filter (lastWord `T.isPrefixOf`) replacementCandidates

  (replacementCandidates, replacementBoundaryPredicate) = case completionType of
    EntityName -> (entityNames, (/= '"'))
    FunctionName -> (possibleWords, isIdentChar)

  possibleWords = reservedWords ++ names

  entityNames = M.keys $ entitiesByName em

  t = repl ^. replPromptText
  setCmd nt ms =
    repl
      & replPromptText .~ nt
      & replPromptType .~ CmdPrompt ms

-- | Validate the REPL input when it changes: see if it parses and
--   typechecks, and set the color accordingly.
validateREPLForm :: AppState -> AppState
validateREPLForm s =
  case replPrompt of
    CmdPrompt _
      | T.null uinput ->
        let theType = s ^. gameState . replStatus . replActiveType
         in s & uiState . uiREPL . replType .~ theType
    CmdPrompt _
      | otherwise ->
        let result = processTerm' (topCtx ^. defTypes) (topCtx ^. defReqs) uinput
            theType = case result of
              Right (Just (ProcessedTerm _ (Module ty _) _ _)) -> Just ty
              _ -> Nothing
         in s
              & uiState . uiREPL . replValid .~ isRight result
              & uiState . uiREPL . replType .~ theType
    SearchPrompt _ -> s
 where
  uinput = s ^. uiState . uiREPL . replPromptText
  replPrompt = s ^. uiState . uiREPL . replPromptType
  topCtx = topContext s

-- | Update our current position in the REPL history.
adjReplHistIndex :: TimeDir -> AppState -> AppState
adjReplHistIndex d s =
  s
    & uiState . uiREPL %~ moveREPL
    & validateREPLForm
 where
  moveREPL :: REPLState -> REPLState
  moveREPL repl =
    newREPL
      & (if replIndexIsAtInput (repl ^. replHistory) then saveLastEntry else id)
      & (if oldEntry /= newEntry then showNewEntry else id)
   where
    -- new AppState after moving the repl index
    newREPL :: REPLState
    newREPL = repl & replHistory %~ moveReplHistIndex d oldEntry

    saveLastEntry = replLast .~ (repl ^. replPromptText)
    showNewEntry = (replPromptEditor .~ newREPLEditor newEntry) . (replPromptType .~ CmdPrompt [])
    -- get REPL data
    getCurrEntry = fromMaybe (repl ^. replLast) . getCurrentItemText . view replHistory
    oldEntry = getCurrEntry repl
    newEntry = getCurrEntry newREPL

------------------------------------------------------------
-- World events
------------------------------------------------------------

worldScrollDist :: Int64
worldScrollDist = 8

onlyCreative :: MonadState AppState m => m () -> m ()
onlyCreative a = do
  c <- use $ gameState . creativeMode
  when c a

-- | Handle a user input event in the world view panel.
handleWorldEvent :: BrickEvent Name AppEvent -> EventM Name AppState ()
-- scrolling the world view in Creative mode
handleWorldEvent = \case
  Key k | k `elem` moveKeys -> onlyCreative $ scrollView (^+^ (worldScrollDist *^ keyToDir k))
  CharKey 'c' -> do
    invalidateCacheEntry WorldCache
    gameState . viewCenterRule .= VCRobot 0
  -- show fps
  CharKey 'f' -> uiState . uiShowFPS %= not
  -- Fall-through case: don't do anything.
  _ -> continueWithoutRedraw
 where
  moveKeys =
    [ V.KUp
    , V.KDown
    , V.KLeft
    , V.KRight
    , V.KChar 'h'
    , V.KChar 'j'
    , V.KChar 'k'
    , V.KChar 'l'
    ]

-- | Manually scroll the world view.
scrollView :: (V2 Int64 -> V2 Int64) -> EventM Name AppState ()
scrollView update = do
  -- Manually invalidate the 'WorldCache' instead of just setting
  -- 'needsRedraw'.  I don't quite understand why the latter doesn't
  -- always work, but there seems to be some sort of race condition
  -- where 'needsRedraw' gets reset before the UI drawing code runs.
  invalidateCacheEntry WorldCache
  gameState %= modifyViewCenter update

-- | Convert a directional key into a direction.
keyToDir :: V.Key -> V2 Int64
keyToDir V.KUp = north
keyToDir V.KDown = south
keyToDir V.KRight = east
keyToDir V.KLeft = west
keyToDir (V.KChar 'h') = west
keyToDir (V.KChar 'j') = south
keyToDir (V.KChar 'k') = north
keyToDir (V.KChar 'l') = east
keyToDir _ = V2 0 0

-- | Adjust the ticks per second speed.
adjustTPS :: (Int -> Int -> Int) -> AppState -> AppState
adjustTPS (+/-) = uiState . lgTicksPerSecond %~ (+/- 1)

------------------------------------------------------------
-- Robot panel events
------------------------------------------------------------

-- | Handle user input events in the robot panel.
handleRobotPanelEvent :: BrickEvent Name AppEvent -> EventM Name AppState ()
handleRobotPanelEvent = \case
  (Key V.KEnter) ->
    gets focusedEntity >>= maybe continueWithoutRedraw descriptionModal
  (CharKey 'm') ->
    gets focusedEntity >>= maybe continueWithoutRedraw makeEntity
  (CharKey '0') -> do
    uiState . uiInventoryShouldUpdate .= True
    uiState . uiShowZero %= not
  (CharKey ';') -> do
    uiState . uiInventoryShouldUpdate .= True
    uiState . uiInventorySort %= cycleSortOrder
  (CharKey ':') -> do
    uiState . uiInventoryShouldUpdate .= True
    uiState . uiInventorySort %= cycleSortDirection
  (VtyEvent ev) -> do
    -- This does not work we want to skip redrawing in the no-list case
    -- Brick.zoom (uiState . uiInventory . _Just . _2) (handleListEventWithSeparators ev (is _Separator))
    mList <- preuse $ uiState . uiInventory . _Just . _2
    case mList of
      Nothing -> continueWithoutRedraw
      Just l -> do
        l' <- nestEventM' l (handleListEventWithSeparators ev (is _Separator))
        uiState . uiInventory . _Just . _2 .= l'
  _ -> continueWithoutRedraw

-- | Attempt to make an entity selected from the inventory, if the
--   base is not currently busy.
makeEntity :: Entity -> EventM Name AppState ()
makeEntity e = do
  s <- get
  let mkTy = PolyUnit
      mkReq = R.singletonCap CMake
      mkProg = TApp (TConst Make) (TText (e ^. entityName))
      mkPT = ProcessedTerm mkProg (Module mkTy empty) mkReq empty
      topStore =
        fromMaybe emptyStore $
          s ^? gameState . baseRobot . robotContext . defStore

  case isActive <$> (s ^? gameState . baseRobot) of
    Just False -> do
      gameState . replStatus .= REPLWorking (Typed Nothing mkTy mkReq)
      gameState . baseRobot . machine .= initMachine mkPT empty topStore
      gameState %= execState (activateRobot 0)
    _ -> continueWithoutRedraw

-- | Display a modal window with the description of an entity.
descriptionModal :: Entity -> EventM Name AppState ()
descriptionModal e = do
  s <- get
  uiState . uiModal ?= generateModal s (DescriptionModal e)

------------------------------------------------------------
-- Info panel events
------------------------------------------------------------

-- | Handle user events in the info panel (just scrolling).
handleInfoPanelEvent :: ViewportScroll Name -> BrickEvent Name AppEvent -> EventM Name AppState ()
handleInfoPanelEvent vs = \case
  Key V.KDown -> vScrollBy vs 1
  Key V.KUp -> vScrollBy vs (-1)
  CharKey 'k' -> vScrollBy vs 1
  CharKey 'j' -> vScrollBy vs (-1)
  Key V.KPageDown -> vScrollPage vs Brick.Down
  Key V.KPageUp -> vScrollPage vs Brick.Up
  Key V.KHome -> vScrollToBeginning vs
  Key V.KEnd -> vScrollToEnd vs
  _ -> return ()
