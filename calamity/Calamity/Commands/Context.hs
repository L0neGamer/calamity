{-# LANGUAGE TemplateHaskell #-}

-- | Command invokation context
module Calamity.Commands.Context (
  CalamityCommandContext (..),
  FullContext (..),
  useFullContext,
  LightContext (..),
  useLightContext,
) where

import Calamity.Cache.Eff
import Calamity.Commands.Types
import Calamity.Internal.Utils
import Calamity.Types.Model.Channel
import Calamity.Types.Model.Guild
import Calamity.Types.Model.User
import Calamity.Types.Snowflake
import Calamity.Types.Tellable
import qualified CalamityCommands.Context as CC
import Control.Applicative
import Control.Monad
import qualified Data.Text as T
import Optics
import qualified Polysemy as P
import qualified Polysemy.Fail as P
import qualified TextShow

class CommandContext c => CalamityCommandContext c where
  -- | The id of the channel that invoked this command
  ctxChannelID :: c -> Snowflake Channel

  -- | The id of the guild the command was invoked in, if in a guild
  ctxGuildID :: c -> Maybe (Snowflake Guild)

  -- | The id of the user that invoked this command
  ctxUserID :: c -> Snowflake User

  -- | The message that triggered this command
  ctxMessage :: c -> Message

-- | Invokation context for commands
data FullContext = FullContext
  { -- | The message that the command was invoked from
    message :: Message
  , -- | If the command was sent in a guild, this will be present
    guild :: Maybe Guild
  , -- | The member that invoked the command, if in a guild
    --
    -- Note: If discord sent a member with the message, this is used; otherwise
    -- we try to fetch the member from the cache.
    member :: Maybe Member
  , -- | The channel the command was invoked from
    channel :: Channel
  , -- | The user that invoked the command
    user :: User
  , -- | The command that was invoked
    command :: Command FullContext
  , -- | The prefix that was used to invoke the command
    prefix :: T.Text
  , -- | The message remaining after consuming the prefix
    unparsedParams :: T.Text
  }
  deriving (Show)
  deriving (TextShow.TextShow) via TextShow.FromStringShow FullContext
  deriving (HasID Channel) via HasIDField "channel" FullContext
  deriving (HasID Message) via HasIDField "message" FullContext
  deriving (HasID User) via HasIDField "user" FullContext

$(makeFieldLabelsNoPrefix ''FullContext)

instance CC.CommandContext IO FullContext () where
  ctxPrefix = (^. #prefix)
  ctxCommand = (^. #command)
  ctxUnparsedParams = (^. #unparsedParams)

instance CalamityCommandContext FullContext where
  ctxChannelID = getID . (^. #channel)
  ctxGuildID c = getID <$> c ^. #guild
  ctxUserID = getID . (^. #user)
  ctxMessage = (^. #message)

instance Tellable FullContext where
  getChannel = pure . ctxChannelID

useFullContext :: P.Member CacheEff r => P.Sem (CC.ConstructContext (Message, User, Maybe Member) FullContext IO () ': r) a -> P.Sem r a
useFullContext =
  P.interpret
    ( \case
        CC.ConstructContext (pre, cmd, up) (msg, usr, mem) -> buildContext msg usr mem pre cmd up
    )

buildContext :: P.Member CacheEff r => Message -> User -> Maybe Member -> T.Text -> Command FullContext -> T.Text -> P.Sem r (Maybe FullContext)
buildContext msg usr mem prefix command unparsed = (rightToMaybe <$>) . P.runFail $ do
  guild <- join <$> getGuild `traverse` (msg ^. #guildID)
  let member = mem <|> guild ^? _Just % #members % ix (coerceSnowflake $ getID @User msg)
  let gchan = guild ^? _Just % #channels % ix (coerceSnowflake $ getID @Channel msg)
  Just channel <- case gchan of
    Just chan -> pure . pure $ GuildChannel' chan
    Nothing -> DMChannel' <<$>> getDM (coerceSnowflake $ getID @Channel msg)

  pure $ FullContext msg guild member channel usr command prefix unparsed

-- | A lightweight context that doesn't need any cache information
data LightContext = LightContext
  { -- | The message that the command was invoked from
    message :: Message
  , -- | If the command was sent in a guild, this will be present
    guildID :: Maybe (Snowflake Guild)
  , -- | The channel the command was invoked from
    channelID :: Snowflake Channel
  , -- | The user that invoked the command
    user :: User
  , -- | The member that triggered the command.
    --
    -- Note: Only sent if discord sent the member object with the message.
    member :: Maybe Member
  , -- | The command that was invoked
    command :: Command LightContext
  , -- | The prefix that was used to invoke the command
    prefix :: T.Text
  , -- | The message remaining after consuming the prefix
    unparsedParams :: T.Text
  }
  deriving (Show)
  deriving (TextShow.TextShow) via TextShow.FromStringShow LightContext
  deriving (HasID Channel) via HasIDField "channelID" LightContext
  deriving (HasID Message) via HasIDField "message" LightContext
  deriving (HasID User) via HasIDField "user" LightContext

$(makeFieldLabelsNoPrefix ''LightContext)

instance CC.CommandContext IO LightContext () where
  ctxPrefix = (^. #prefix)
  ctxCommand = (^. #command)
  ctxUnparsedParams = (^. #unparsedParams)

instance CalamityCommandContext LightContext where
  ctxChannelID = (^. #channelID)
  ctxGuildID = (^. #guildID)
  ctxUserID = (^. #user % #id)
  ctxMessage = (^. #message)

instance Tellable LightContext where
  getChannel = pure . ctxChannelID

useLightContext :: P.Sem (CC.ConstructContext (Message, User, Maybe Member) LightContext IO () ': r) a -> P.Sem r a
useLightContext =
  P.interpret
    ( \case
        CC.ConstructContext (pre, cmd, up) (msg, usr, mem) ->
          pure . Just $ LightContext msg (msg ^. #guildID) (msg ^. #channelID) usr mem cmd pre up
    )
