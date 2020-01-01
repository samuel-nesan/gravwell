{-# language RecordWildCards #-}
module Game where

-- import Data.List (sort)

-- import Debug.Trace

-- import Data.Ord
import Card
import Control.Lens hiding (modifying, use, assign)
import Control.Monad.Random
import Data.Foldable (for_)
import Data.Generics.Labels ()
-- import Control.Monad
import Data.List
-- import Data.Map.Lazy (Map)
-- import qualified Data.Map.Lazy as Map
-- import Data.Maybe
import Data.Set (Set)
import qualified Data.Set as Set
-- import Data.Traversable
import GHC.Generics (Generic)
import Player
-- import System.Random (StdGen)
-- import qualified System.Random as Random
-- import System.Random.Shuffle (shuffle')
import Control.Algebra
import Control.Carrier.State.Strict
import Zoomy
import RandomEffect
import Control.Effect.Lens (modifying, use, assign)

data Game = Game
  { gamePlayer1 :: Player
  , gamePlayer2 :: Player
  , gamePlayer3 :: Player
  , gamePlayer4 :: Player
  , gameDerelict1 :: Int
  , gameDerelict2 :: Int
  , gameState :: GameState
  , gameUnplayedCards :: [(Int, Card)]
  } deriving stock (Show, Generic)

data GameState
  = DraftBegan (forall sig m.
      (Has RandomEffect sig m, Effect sig) => m Game)
  | PickCard (forall sig m.
      (Has RandomEffect sig m, Effect sig) => Int -> Maybe (m Game))
  | ResolvingMovement (forall sig m.
      (Algebra sig m, Effect sig) => m Game)
  | RoundEnded Game

instance Show GameState where
  show = \case
    DraftBegan{} -> "DraftBegan"
    PickCard{} -> "PickCard"
    ResolvingMovement{} -> "ResolvingMovement"
    RoundEnded{} -> "RoundEnded"

-- The current number of players supported
numPlayers :: Int
numPlayers = 4

-- | Returns 1 (forwards), -1 (backwards), or 0 (nowhere) per the natural motion
-- direction of the given index in the game.
gameMotion :: Game -> Int -> Int
gameMotion game i =
  case comp1 <> comp2 of
    LT -> -1
    EQ -> 0
    GT -> 1
  where
    comp1 = compare closestShipBehind closestShipAhead
    comp2 = compare numShipsAhead numShipsBehind

    (shipsBehind, shipsAhead) = Set.split i ships

    closestShipBehind = case (Set.lookupMax shipsBehind) of
      Nothing -> maxBound
      Just n -> i - n

    closestShipAhead = case (Set.lookupMin shipsAhead) of
      Nothing -> maxBound
      Just n ->  n - i

    numShipsBehind = length shipsBehind
    numShipsAhead = length shipsAhead

    ships :: Set Int
    ships = gameShips game

gamePlayers :: Game -> [Player]
gamePlayers game =
  [ gamePlayer1 game
  , gamePlayer2 game
  , gamePlayer3 game
  , gamePlayer4 game
  ]

gamePlayerByNum :: Int -> Lens' Game Player
gamePlayerByNum = \case
  1 -> #gamePlayer1
  2 -> #gamePlayer2
  3 -> #gamePlayer3
  4 -> #gamePlayer4
  _ -> error "invalid player number"

gameOtherShips :: Int -> ([ALens' Game Int])
gameOtherShips = \case
  1 -> [ #gamePlayer2 . #playerShip
       , #gamePlayer3 . #playerShip
       , #gamePlayer4 . #playerShip
       , #gameDerelict1, #gameDerelict2]
  2 -> [ #gamePlayer1 . #playerShip
       , #gamePlayer3 . #playerShip
       , #gamePlayer4 . #playerShip
       , #gameDerelict1, #gameDerelict2]
  3 -> [ #gamePlayer1 . #playerShip
       , #gamePlayer2 . #playerShip
       , #gamePlayer4 . #playerShip
       , #gameDerelict1, #gameDerelict2]
  4 -> [ #gamePlayer1 . #playerShip
       , #gamePlayer2 . #playerShip
       , #gamePlayer3 . #playerShip
       , #gameDerelict1, #gameDerelict2]
  _ -> error "invalid player number"


gameOver :: Game -> Bool
gameOver game = any (>= gameWarpGate) (gameShipsList game)

gameWarpGate :: Int
gameWarpGate = 30

-- | Positions of all ships in the game
gameShips :: Game -> Set Int
gameShips = Set.fromList . gameShipsList

gameShipsList :: Game -> [Int]
gameShipsList game =
  [ gameDerelict1 game
  , gameDerelict2 game
  ] ++ map (view #playerShip) (gamePlayers game)

-- The initial game state
initialGame :: Game
initialGame = setStateDraftBegan
  Game
    { gamePlayer1 = Player 0 []
    , gamePlayer2 = Player 0 []
    , gamePlayer3 = Player 0 []
    , gamePlayer4 = Player 0 []
    , gameDerelict1 = 10
    , gameDerelict2 = 20
    , gameState = undefined -- intentionally undefined, will be set later
    , gameUnplayedCards = []
    }

-- Sets the game state of this Game to PickCard
setStatePickCard :: Game -> Game
setStatePickCard game0 = game1
  where
    -- f :: Int -> Maybe Game
    -- f x = if x >= length (game1 ^. #gamePlayer1 . #playerHand)
    --   then Nothing
    --   else Just $ handlePlayCard x game1

    f :: (Has RandomEffect sig m, Effect sig) => Int -> Maybe (m Game)
    f x = if x >= length (game1 ^. #gamePlayer1 . #playerHand)
      then Nothing
      else Just (handlePickCards x & execState game1)

    game1 :: Game
    game1 = game0 { gameState = PickCard f }

setStateResolvingMovement :: Game -> Game
setStateResolvingMovement game0 = game1
  where
    game1 :: Game
    game1 = game0 { gameState =
      ResolvingMovement (handleResolveCard & execState game1) }

-- Sets the game state of this Game to DraftBegan
setStateDraftBegan :: Game -> Game
setStateDraftBegan game0 = game1
  where
    game1 :: Game
    game1 = game0
      { gameState = DraftBegan (handleDraftGame & execState game1) }

-- Sets the game state of this Game to RoundEnded
setStateRoundEnded :: Game -> Game
setStateRoundEnded game0 = game1
  where
    game1 :: Game
    game1 = game0 { gameState = RoundEnded game2 }

    game2 :: Game
    game2 = setStateDraftBegan game1

handleResolveCard :: (Has (State Game) sig m, Effect sig) => m ()
handleResolveCard = do
  ~((playerNum, card):cards) <- use @Game #gameUnplayedCards
  assign @Game #gameUnplayedCards cards
  playCard
    card
    (gamePlayerByNum playerNum . #playerShip)
    (gameOtherShips playerNum)

  hand <- use @Game (#gamePlayer1 . #playerHand)

  modify
    if null cards
    then
      if null hand
      then setStateRoundEnded
      else setStatePickCard
    else setStateResolvingMovement

handleDraftGame
  :: (Has (State Game) sig m, Has RandomEffect sig m, Effect sig) => m ()
handleDraftGame = do
  deck' <- shuffleCards deck

  let
    (draftHand1, (draftHand2, (draftHand3, (draftHand4, _))))
      =             (splitAt 6 deck') -- hand 1
      & _2 %~       (splitAt 6) -- hand 2
      & _2._2 %~    (splitAt 6) -- hand 3
      & _2._2._2 %~ (splitAt 6) -- hand 4

  modify @Game (\game -> game
    & #gamePlayer1 . #playerHand .~ draftHand1
    & #gamePlayer2 . #playerHand .~ draftHand2
    & #gamePlayer3 . #playerHand .~ draftHand3
    & #gamePlayer4 . #playerHand .~ draftHand4
    & setStatePickCard
    )

aiPickCard
  :: (Has RandomEffect sig m, Has (State Player) sig m)
  => m Card
aiPickCard = do
  player <- get
  let range = length (player ^. #playerHand) - 1
  i <- randomInt 0 range
  let (card, player') = pluckPlayer i player
  put player'
  pure card

handlePickCards :: forall sig m.
  (Has (State Game) sig m, Has RandomEffect sig m, Effect sig) => Int -> m ()
handlePickCards x = do
  let
    aiPicks :: m ()
    aiPicks =
      for_ [2, 3, 4] \playerNum -> do
        let
          player :: Lens' Game Player
          player = cloneLens $ gamePlayerByNum playerNum
        card <- zoomy player aiPickCard
        modifying @Game #gameUnplayedCards  ((playerNum, card) :)

    pick :: m ()
    pick = do
      card <- zoomy @Game (#gamePlayer1 . #playerHand) (pluckCard'FE x)
      modifying @Game #gameUnplayedCards  ((1, card) :)
      -- l @Game #gameUnplayedCards %= ((1,card) :)

    -- picks :: m [(Int, Card)]
    -- picks = do
    --   card <- pick
    --   ais <- aiPicks
    --   pure $ orderPicks ((1, card):ais)

    orderPicks :: [(a, Card)] -> [(a, Card)]
    orderPicks = sortOn (view (_2 . #cardSymbol))

  aiPicks
  pick
  modifying @Game #gameUnplayedCards orderPicks
  modify setStateResolvingMovement

l :: Lens' a b -> Lens' a b
l = id

playCard
  :: (Has (State Game) sig m, Effect sig)
  => Card
  -> Lens' Game Int
  -> [ALens' Game Int]
  -> m ()
playCard card ship otherShips = do
  let moveAmount = cardAmount card
  case cardType card of
    Fuel ->
      modify \game ->
        moveShip' moveAmount (gameMotion game) ship game
    Repulsor ->
      modify \game ->
        moveShip' moveAmount (negate . gameMotion game) ship game
    Tractor -> do
      game <- get
      let otherShips' = otherShips
      for_ otherShips' \(cloneLens -> otherShip) ->
        let
          p1 = game ^. ship
          f :: Int -> Int
          f p2 = signum (p1 - p2)

        in modify (moveShip' moveAmount f otherShip)

-- Play this Card and determine the resulting Game
moveShip
  :: Set Int -- occupied spaces
  -> (Int -> Int) -- motion
  -> Int -- fuel amount
  -> Int -- starting pos
  -> Int
moveShip ships f fuel start =
    let
      motion :: Int
      motion =  f start

      move :: Int
      move = motion * fuel

      openPos :: Int -> Int
      openPos pos = if pos `Set.member` ships
        then openPos (pos + motion)
        else pos

      candidatePos :: Int
      candidatePos = start + move

      newPosition :: Int
      newPosition = max 0 $ if motion == 0
        then candidatePos
        else openPos candidatePos

    in newPosition

moveShip'
  :: Int -- fuel amount
  -> (Int -> Int) -- motion
  -> Lens' Game Int -- The ship that is moving
  -> Game -- starting pos
  -> Game
moveShip' fuel f ship game =
  game & ship %~ moveShip (gameShips game) f fuel

validateGame :: Game -> IO ()
validateGame game@(Game { .. })  = do
  when
    (has
      ( folded
      . #playerHand
      . filtered ((>6)
      . length))
      ( gamePlayers game ))
    -- (any (\player -> length (playerHand player) > 6) (gamePlayers game))
    (die "Hand exceeded 6 cards")

  when (any (<0) (gameShips game)) (die "Ship index cannot be negative")

  when
    (length (filter (>=gameWarpGate) (gameShipsList game)) > 1)
    (die "Two ships cannot be in the warp gate at once")

  do
    let
      xs :: [Int]
      xs = filter (/=0) (gameShipsList game)

    when (length xs /= length (nub xs))
      (die "Ships cannot be on top of each other outside of singularity")

  where
    die :: [Char] -> IO ()
    die s = do
      print game
      fail s
