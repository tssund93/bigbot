{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}

module Lib (bigbot) where

import Control.Lens (view, (&), (.~))
import Control.Monad (filterM, when)
import Control.Monad.Catch (catchAll, catchIOError)
import Control.Monad.Reader (MonadTrans (lift), ReaderT (runReaderT), asks, forM_, liftIO)
import Data.Aeson (
    FromJSON (parseJSON),
    defaultOptions,
    eitherDecode,
    fieldLabelModifier,
    genericParseJSON,
    withObject,
    (.:),
 )
import qualified Data.ByteString.Lazy as BSL
import Data.Char (toLower)
import Data.Either.Combinators (maybeToRight)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List (delete, nub, stripPrefix)
import Data.Maybe (fromMaybe)
import Data.Text (Text, intercalate)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.IO as T
import Data.Time (defaultTimeLocale, formatTime, getCurrentTime, getCurrentTimeZone, utcToLocalTime)
import Data.Yaml (decodeFileEither)
import qualified Discord as D
import qualified Discord.Internal.Rest as D
import qualified Discord.Requests as D
import GHC.Generics (Generic)
import Network.Wreq (
    Response,
    defaults,
    get,
    getWith,
    header,
    param,
    responseBody,
 )
import qualified Network.Wreq as W
import System.Environment (getArgs)
import System.Random (Random (randomIO))
import Text.Read (readMaybe)

type App a = ReaderT Config D.DiscordHandler a

data Db = Db
    { dbResponses :: [Text]
    , dbActivity :: Maybe Text
    }
    deriving (Show, Read)

defaultDb :: Db
defaultDb = Db{dbResponses = ["hi"], dbActivity = Nothing}

data Config = Config
    { configDictKey :: Maybe Text
    , configUrbanKey :: Maybe Text
    , configCommandPrefix :: Text
    , configDb :: IORef Db
    , configDbFile :: FilePath
    }

data UserConfig = UserConfig
    { userConfigDiscordToken :: Text
    , userConfigDictKey :: Maybe Text
    , userConfigUrbanKey :: Maybe Text
    , userConfigCommandPrefix :: Maybe Text
    , userConfigDbFile :: Maybe FilePath
    }
    deriving (Generic, Show)

instance FromJSON UserConfig where
    parseJSON =
        genericParseJSON
            defaultOptions
                { fieldLabelModifier = stripJSONPrefix "userConfig"
                }

stripJSONPrefix :: String -> String -> String
stripJSONPrefix prefix s =
    case stripPrefix prefix s of
        Just (c : rest) -> toLower c : rest
        _ -> s

defaultConfigFile :: FilePath
defaultConfigFile = "config.yaml"

defaultDbFile :: FilePath
defaultDbFile = "db"

logText :: Text -> IO ()
logText t = do
    now <- getCurrentTime
    tz <- getCurrentTimeZone
    T.putStrLn $
        T.pack (formatTime defaultTimeLocale "%F %T" $ utcToLocalTime tz now)
            <> ": "
            <> t

bigbot :: IO ()
bigbot = do
    args <- getArgs
    let configFile = case args of
            [] -> defaultConfigFile
            [path] -> path
            _ -> error "too many arguments provided: expected at most 1"
    config@UserConfig{..} <-
        either (error . show) id <$> decodeFileEither configFile
    dbStr <-
        ( Just
                <$> readFile
                    (fromMaybe defaultDbFile userConfigDbFile)
            )
            `catchIOError` \_ -> return Nothing
    let mdb = dbStr >>= readMaybe
    let db = fromMaybe defaultDb mdb
    dbRef <- newIORef db
    userFacingError <-
        D.runDiscord
            ( D.def
                { D.discordToken = userConfigDiscordToken
                , D.discordOnStart = onStart config
                , D.discordOnEvent = eventHandler config dbRef
                , D.discordOnLog = logText
                }
            )
            `catchAll` \e -> return $ T.pack $ show e
    T.putStrLn userFacingError

onStart :: UserConfig -> D.DiscordHandler ()
onStart config =
    liftIO $ logText $ "bot started with config " <> T.pack (show config)

updateStatus :: Maybe Text -> D.DiscordHandler ()
updateStatus mactivity =
    D.sendCommand $
        D.UpdateStatus $
            D.UpdateStatusOpts
                { D.updateStatusOptsSince = Nothing
                , D.updateStatusOptsGame = case mactivity of
                    Just activity ->
                        Just $ D.Activity activity D.ActivityTypeGame Nothing
                    Nothing -> Nothing
                , D.updateStatusOptsNewStatus = D.UpdateStatusOnline
                , D.updateStatusOptsAFK = False
                }

eventHandler :: UserConfig -> IORef Db -> D.Event -> D.DiscordHandler ()
eventHandler UserConfig{..} dbRef event = do
    let config =
            Config
                { configDictKey = userConfigDictKey
                , configUrbanKey = userConfigUrbanKey
                , configCommandPrefix = fromMaybe "!" userConfigCommandPrefix
                , configDb = dbRef
                , configDbFile =
                    fromMaybe defaultDbFile userConfigDbFile
                }
    flip runReaderT config $
        case event of
            D.Ready{} -> ready dbRef
            D.MessageCreate message -> messageCreate message
            D.TypingStart typingInfo -> typingStart typingInfo
            _ -> pure ()

ready :: IORef Db -> App ()
ready dbRef = do
    liftIO $ logText "received ready event, updating activity"
    Db{dbActivity = mactivity} <- liftIO $ readIORef dbRef
    lift $ updateStatus mactivity

type Command = D.Message -> App ()
type CommandPredicate = D.Message -> App Bool

commands :: [(CommandPredicate, Command)]
commands =
    [ (isCommand "rr", russianRoulette)
    , (isCommand "define", define)
    , (isCommand "add", addResponse)
    , (isCommand "remove", removeResponse)
    , (isCommand "list", listResponses)
    , (isCommand "playing", setPlaying)
    , (mentionsMe, respond)
    ]

messageCreate :: D.Message -> App ()
messageCreate message
    | not (fromBot message) = do
        matches <- filterM (\(p, _) -> p message) commands
        case matches of
            ((_, cmd) : _) -> cmd message
            _ -> pure ()
    | D.userId (D.messageAuthor message) == 235148962103951360 =
        simpleReply "Carl is a cuck" message
    | otherwise = pure ()

typingStart :: D.TypingInfo -> App ()
typingStart (D.TypingInfo userId channelId _utcTime) = do
    shouldReply <- liftIO $ (== 0) . (`mod` 1000) <$> (randomIO :: IO Int)
    when shouldReply $
        createMessage channelId $ T.pack $ "shut up <@" <> show userId <> ">"

restCall :: (FromJSON a, D.Request (r a)) => r a -> App ()
restCall request = do
    r <- lift $ D.restCall request
    case r of
        Right _ -> pure ()
        Left err -> liftIO $ print err

createMessage :: D.ChannelId -> Text -> App ()
createMessage channelId message = do
    let chunks = T.chunksOf 2000 message
    forM_ chunks $ \chunk -> restCall $ D.CreateMessage channelId chunk

createGuildBan :: D.GuildId -> D.UserId -> Text -> App ()
createGuildBan guildId userId banMessage =
    restCall $
        D.CreateGuildBan
            guildId
            userId
            (D.CreateGuildBanOpts Nothing (Just banMessage))

fromBot :: D.Message -> Bool
fromBot m = D.userIsBot (D.messageAuthor m)

russianRoulette :: Command
russianRoulette message = do
    chamber <- liftIO $ (`mod` 6) <$> (randomIO :: IO Int)
    case (chamber, D.messageGuild message) of
        (0, Just gId) -> do
            createMessage (D.messageChannel message) response
            createGuildBan gId (D.userId $ D.messageAuthor message) response
          where
            response = "Bang!"
        _ -> createMessage (D.messageChannel message) "Click."

data Definition = Definition
    { defPartOfSpeech :: Maybe Text
    , defDefinitions :: [Text]
    }
    deriving (Show)

instance FromJSON Definition where
    parseJSON = withObject "Definition" $ \v -> do
        partOfSpeech <- v .: "fl"
        definitions <- v .: "shortdef"
        pure
            Definition
                { defPartOfSpeech = partOfSpeech
                , defDefinitions = definitions
                }

define :: Command
define message = do
    let (_ : wordsToDefine) = words $ T.unpack $ D.messageText message
    case wordsToDefine of
        [] ->
            createMessage
                (D.messageChannel message)
                "Missing word/phrase to define"
        wtd -> do
            let phrase = unwords wtd
            moutput <- getDefineOutput phrase
            case moutput of
                Just output -> createMessage (D.messageChannel message) output
                Nothing ->
                    createMessage (D.messageChannel message) $
                        "No definition found for **" <> T.pack phrase <> "**"

buildDefineOutput :: String -> Definition -> Text
buildDefineOutput word definition = do
    let shortDefinition = defDefinitions definition
        mpartOfSpeech = defPartOfSpeech definition
        definitions = case shortDefinition of
            [def] -> def
            defs ->
                T.intercalate "\n\n" $
                    zipWith
                        (\i def -> T.pack (show i) <> ". " <> def)
                        [1 :: Int ..]
                        defs
        formattedOutput =
            "**" <> T.pack word <> "**"
                <> ( case mpartOfSpeech of
                        Just partOfSpeech -> " *" <> partOfSpeech <> "*"
                        Nothing -> ""
                   )
                <> "\n"
                <> definitions
     in formattedOutput

getDefineOutput :: String -> App (Maybe Text)
getDefineOutput word = do
    response <- getDictionaryResponse word
    buildDefineOutputHandleFail
        word
        ( maybeToRight
            "no dictionary.com api key set"
            (fmap (view responseBody) response)
            >>= eitherDecode
        )
        $ Just $ do
            urbanResponse <- getUrbanResponse word
            buildDefineOutputHandleFail
                word
                ( maybeToRight
                    "no urban dictionary api key set"
                    (fmap (view responseBody) urbanResponse)
                    >>= decodeUrban
                )
                Nothing

buildDefineOutputHandleFail ::
    String ->
    Either String [Definition] ->
    Maybe (App (Maybe Text)) ->
    App (Maybe Text)
buildDefineOutputHandleFail word (Right defs) _
    | not (null defs) =
        pure $
            Just $
                T.intercalate "\n\n" $
                    map (buildDefineOutput word) defs
buildDefineOutputHandleFail _ (Left err) Nothing =
    liftIO (print err) >> pure Nothing
buildDefineOutputHandleFail _ (Left _) (Just fallback) = fallback
buildDefineOutputHandleFail _ _ (Just fallback) = fallback
buildDefineOutputHandleFail _ (Right _) Nothing = pure Nothing

getDictionaryResponse :: String -> App (Maybe (Response BSL.ByteString))
getDictionaryResponse word = do
    mapiKey <- asks configDictKey
    case mapiKey of
        Nothing -> pure Nothing
        Just apiKey ->
            liftIO $
                fmap Just <$> get $
                    T.unpack $
                        "https://dictionaryapi.com/api/v3/references/collegiate/json/"
                            <> T.pack word
                            <> "?key="
                            <> apiKey

getUrbanResponse :: String -> App (Maybe (Response BSL.ByteString))
getUrbanResponse word = do
    mapiKey <- asks configUrbanKey
    case mapiKey of
        Nothing -> pure Nothing
        Just apiKey ->
            liftIO $
                Just
                    <$> getWith
                        (urbanOpts apiKey word)
                        "https://mashape-community-urban-dictionary.p.rapidapi.com/define"

urbanOpts :: Text -> String -> W.Options
urbanOpts apiKey term =
    defaults
        & header "x-rapidapi-key" .~ [T.encodeUtf8 apiKey]
        & header "x-rapidapi-host" .~ ["mashape-community-urban-dictionary.p.rapidapi.com"]
        & header "useQueryString" .~ ["true"]
        & param "term" .~ [T.pack term]

newtype UrbanDefinition = UrbanDefinition {urbanDefDefinition :: [Text]}
    deriving (Show)

instance FromJSON UrbanDefinition where
    parseJSON = withObject "UrbanDefinition" $ \v -> do
        list <- v .: "list"
        defs <- traverse (.: "definition") list
        pure UrbanDefinition{urbanDefDefinition = defs}

decodeUrban :: BSL.ByteString -> Either String [Definition]
decodeUrban = fmap urbanToDictionary . eitherDecode

urbanToDictionary :: UrbanDefinition -> [Definition]
urbanToDictionary (UrbanDefinition def) =
    [Definition Nothing def | not (null def)]

mentionsMe :: D.Message -> App Bool
mentionsMe message = do
    cache <- lift D.readCache
    pure $
        D.userId (D._currentUser cache)
            `elem` map D.userId (D.messageMentions message)

respond :: Command
respond message
    | "thanks" `T.isInfixOf` T.toLower (D.messageText message)
        || "thank you" `T.isInfixOf` T.toLower (D.messageText message)
        || "thx" `T.isInfixOf` T.toLower (D.messageText message)
        || "thk" `T.isInfixOf` T.toLower (D.messageText message) =
        createMessage (D.messageChannel message) "u r welcome"
    | "hi" `T.isInfixOf` T.toLower (D.messageText message)
        || "hello" `T.isInfixOf` T.toLower (D.messageText message)
        || "yo" `T.isInfixOf` T.toLower (D.messageText message)
        || "sup" `T.isInfixOf` T.toLower (D.messageText message)
        || ( "what" `T.isInfixOf` T.toLower (D.messageText message)
                && "up" `T.isInfixOf` T.toLower (D.messageText message)
           )
        || "howdy" `T.isInfixOf` T.toLower (D.messageText message) =
        createMessage (D.messageChannel message) "hi"
    | "wb" `T.isInfixOf` T.toLower (D.messageText message)
        || "welcom" `T.isInfixOf` T.toLower (D.messageText message)
        || "welcum" `T.isInfixOf` T.toLower (D.messageText message) =
        createMessage (D.messageChannel message) "thx"
    | "mornin" `T.isInfixOf` T.toLower (D.messageText message)
        || "gm" `T.isInfixOf` T.toLower (D.messageText message) =
        createMessage (D.messageChannel message) "gm"
    | "night" `T.isInfixOf` T.toLower (D.messageText message)
        || "gn" `T.isInfixOf` T.toLower (D.messageText message) =
        createMessage (D.messageChannel message) "gn"
    | "how" `T.isInfixOf` T.toLower (D.messageText message)
        && ( " u" `T.isInfixOf` T.toLower (D.messageText message)
                || " you" `T.isInfixOf` T.toLower (D.messageText message)
           ) =
        createMessage (D.messageChannel message) "i am fine thank u and u?"
    | otherwise = do
        db <- asks configDb
        responses <- liftIO $ dbResponses <$> readIORef db
        responseNum <- liftIO $ (`mod` length responses) <$> (randomIO :: IO Int)
        createMessage (D.messageChannel message) $ responses !! responseNum

isCommand :: Text -> CommandPredicate
isCommand command message = do
    prefix <- asks configCommandPrefix
    pure $ messageStartsWith (prefix <> command) message

messageStartsWith :: Text -> D.Message -> Bool
messageStartsWith text = (text `T.isPrefixOf`) . T.toLower . D.messageText

simpleReply :: Text -> Command
simpleReply replyText message =
    createMessage
        (D.messageChannel message)
        replyText

addResponse :: Command
addResponse message = do
    let (_ : postCommand) = words $ T.unpack $ D.messageText message
    case postCommand of
        [] -> createMessage (D.messageChannel message) "Missing response to add"
        pc -> do
            let response = T.pack $ unwords pc
            dbRef <- asks configDb
            dbFileName <- asks configDbFile
            liftIO $
                atomicModifyIORef'
                    dbRef
                    ( \d ->
                        (d{dbResponses = nub $ response : dbResponses d}, ())
                    )
            db <- liftIO $ readIORef dbRef
            liftIO $ writeFile dbFileName $ show db
            createMessage (D.messageChannel message) $
                "Added **" <> response <> "** to responses"

removeResponse :: Command
removeResponse message = do
    let (_ : postCommand) = words $ T.unpack $ D.messageText message
    case postCommand of
        [] ->
            createMessage
                (D.messageChannel message)
                "Missing response to remove"
        pc -> do
            let response = T.pack $ unwords pc
            dbRef <- asks configDb
            dbFileName <- asks configDbFile
            oldResponses <- liftIO $ dbResponses <$> readIORef dbRef
            if response `elem` oldResponses
                then do
                    liftIO $
                        atomicModifyIORef'
                            dbRef
                            ( \d ->
                                ( d
                                    { dbResponses =
                                        delete response $ dbResponses d
                                    }
                                , ()
                                )
                            )
                    db <- liftIO $ readIORef dbRef
                    liftIO $ writeFile dbFileName $ show db
                    createMessage (D.messageChannel message) $
                        "Removed **" <> response <> "** from responses"
                else
                    createMessage (D.messageChannel message) $
                        "Response **" <> response <> "** not found"

listResponses :: Command
listResponses message = do
    dbRef <- asks configDb
    responses <- liftIO $ intercalate "\n" . dbResponses <$> readIORef dbRef
    createMessage (D.messageChannel message) responses

setPlaying :: Command
setPlaying message = do
    dbRef <- asks configDb
    dbFileName <- asks configDbFile
    let (_ : postCommand) = words $ T.unpack $ D.messageText message
    case postCommand of
        [] -> do
            lift $ updateStatus Nothing
            liftIO $
                atomicModifyIORef'
                    dbRef
                    (\d -> (d{dbActivity = Nothing}, ()))
            createMessage (D.messageChannel message) "Removed status"
        pc -> do
            let status = T.pack $ unwords pc
            lift $ updateStatus $ Just status
            liftIO $
                atomicModifyIORef'
                    dbRef
                    (\d -> (d{dbActivity = Just status}, ()))
            createMessage (D.messageChannel message) $
                "Updated status to **" <> status <> "**"
    liftIO $ do
        db <- readIORef dbRef
        writeFile dbFileName $ show db
