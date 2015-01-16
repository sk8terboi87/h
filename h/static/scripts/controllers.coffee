class AppController
  this.$inject = [
    '$location', '$route', '$scope', '$timeout', '$window',
    'annotator', 'auth', 'documentHelpers', 'drafts', 'flash', 'identity',
    'permissions', 'streamer', 'streamfilter'
  ]
  constructor: (
     $location,   $route,   $scope,   $timeout,   $window,
     annotator,   auth,   documentHelpers,   drafts,   flash,   identity,
     permissions,   streamer,   streamfilter,

  ) ->
    {plugins, host, providers} = annotator

    $scope.auth = auth
    isFirstRun = $location.search().hasOwnProperty('firstrun')
    streamerUrl = documentHelpers.baseURI.replace(/^http/, 'ws') + 'ws'

    applyUpdates = (action, data) ->
      # Update the application with new data from the websocket.
      return unless data?.length
      switch action
        when 'create', 'update', 'past'
          plugins.Store?._onLoadAnnotations data
        when 'delete'
          for annotation in data
            annotation = plugins.Threading.idTable[annotation.id]?.message
            continue unless annotation?
            plugins.Store?.unregisterAnnotation(annotation)
            annotator.deleteAnnotation(annotation)

    streamer.onmessage = (data) ->
      if !data or data.type != 'annotation-notification'
        return

      action = data.options.action
      payload = data.payload

      if $scope.socialView.name is 'single-player'
        payload = payload.filter (ann) -> ann.user is auth.user

      applyUpdates(action, payload)
      $scope.$digest()

    initStore = ->
      # Initialize the storage component.
      Store = plugins.Store
      delete plugins.Store

      if auth.user or annotator.socialView.name is 'none'
        annotator.addPlugin 'Store', annotator.options.Store

        $scope.store = plugins.Store

      return unless Store
      Store.destroy()

      # XXX: Hacky hacky stuff to ensure that any search requests in-flight
      # at this time have no effect when they resolve and that future events
      # have no effect on this Store. Unfortunately, it's not possible to
      # unregister all the events or properly unload the Store because the
      # registration loses the closure. The approach here is perhaps
      # cleaner than fishing them out of the jQuery private data.
      # * Overwrite the Store's handle to the annotator, giving it one
      #   with a noop `loadAnnotations` method.
      Store.annotator = loadAnnotations: angular.noop
      # * Make all api requests into a noop.
      Store._apiRequest = angular.noop
      # * Ignore pending searches
      Store._onLoadAnnotations = angular.noop
      # * Make the update function into a noop.
      Store.updateAnnotation = angular.noop

      # Sort out which annotations should remain in place.
      user = auth.user
      view = annotator.socialView.name
      cull = (acc, annotation) ->
        if view is 'single-player' and annotation.user != user
          acc.drop.push annotation
        else if permissions.permits('read', annotation, user)
          acc.keep.push annotation
        else
          acc.drop.push annotation
        acc

      {keep, drop} = Store.annotations.reduce cull, {keep: [], drop: []}
      Store.annotations = []

      if plugins.Store?
        plugins.Store.annotations = keep
      else
        drop = drop.concat keep

      # Clean up the ones that should be removed.
      do cleanup = (drop) ->
        return if drop.length == 0
        [first, rest...] = drop
        annotator.deleteAnnotation first
        $timeout -> cleanup rest

    oncancel = ->
      $scope.dialog.visible = false

    reset = ->
      $scope.dialog.visible = false

      # Update any edits in progress.
      for draft in drafts.all()
        annotator.publish 'beforeAnnotationCreated', draft

      # Reload services
      initStore()

      streamer.close()
      streamer.open($window.WebSocket, streamerUrl)

    $scope.$watch 'socialView.name', (newValue, oldValue) ->
      return if newValue is oldValue
      initStore()
      if newValue is 'single-player' and not auth.user
        annotator.show()
        flash 'info',
          'You will need to sign in for your highlights to be saved.'

    $scope.$watch 'sort.name', (name) ->
      return unless name
      predicate = switch name
        when 'Newest' then ['-!!message', '-message.updated']
        when 'Oldest' then ['-!!message',  'message.updated']
        when 'Location' then ['-!!message', 'message.target[0].pos.top']
      $scope.sort = {name, predicate}

    $scope.$watch 'store.entities', (entities, oldEntities) ->
      return if entities is oldEntities

      if entities.length
        streamfilter
          .resetFilter()
          .addClause('/uri', 'one_of', entities)

        streamer.send({filter: streamfilter.getFilter()})

    $scope.$watch 'auth.user', (newVal, oldVal) ->
      return if newVal is undefined
      reset()
      $scope.login() if isFirstRun and not (newVal or oldVal)

    $scope.login = ->
      $scope.dialog.visible = true
      identity.request {oncancel}

    $scope.logout = ->
      return unless drafts.discard()
      $scope.dialog.visible = false
      identity.logout()

    $scope.loadMore = (number) ->
      unless streamfilter.getPastData().hits then return
      streamer.send({messageType: 'more_hits', moreHits: number})

    $scope.clearSelection = ->
      $scope.search.query = ''
      $scope.selectedAnnotations = null
      $scope.selectedAnnotationsCount = 0

    $scope.dialog = visible: false

    $scope.search =
      query: $location.search()['q']

      clear: ->
        $location.search('q', null)

      update: (query) ->
        unless angular.equals $location.search()['q'], query
          $location.search('q', query or null)
          delete $scope.selectedAnnotations
          delete $scope.selectedAnnotationsCount

    $scope.socialView = annotator.socialView
    $scope.sort = name: 'Location'
    $scope.threading = plugins.Threading


class AnnotationViewerController
  this.$inject = [
    '$location', '$routeParams', '$scope',
    'annotator', 'streamer', 'streamfilter'
  ]
  constructor: (
     $location,   $routeParams,   $scope,
     annotator,   streamer,   streamfilter
  ) ->
    # Tells the view that these annotations are standalone
    $scope.isEmbedded = false
    $scope.isStream = false

    # Clear out loaded annotations and threads
    # XXX: Resolve threading, storage, and streamer better for all routes.
    annotator.plugins.Threading?.pluginInit()
    annotator.plugins.Store?.annotations = []

    # Provide no-ops until these methods are moved elsewere. They only apply
    # to annotations loaded into the stream.
    $scope.focus = angular.noop

    $scope.shouldShowThread = -> true

    $scope.search.update = (query) ->
      $location.path('/stream').search('q', query)

    id = $routeParams.id

    $scope.$watch 'store', ->
      if $scope.store
        $scope.store.loadAnnotationsFromSearch({_id: id}).then ->
          $scope.store.loadAnnotationsFromSearch({references: id})

    streamfilter
      .setPastDataNone()
      .setMatchPolicyIncludeAny()
      .addClause('/references', 'first_of', id, true)
      .addClause('/id', 'equals', id, true)

    streamer.send({filter: streamfilter.getFilter()})

class ViewerController
  this.$inject = ['$scope', 'annotator']
  constructor:   ( $scope,   annotator ) ->
    # Tells the view that these annotations are embedded into the owner doc
    $scope.isEmbedded = true
    $scope.isStream = true

    $scope.focus = (annotation) ->
      if angular.isObject annotation
        highlights = [annotation.$$tag]
      else
        highlights = []
      for p in annotator.providers
        p.channel.notify
          method: 'focusAnnotations'
          params: highlights

    $scope.scrollTo = (annotation) ->
      if angular.isObject annotation
        for p in annotator.providers
          p.channel.notify
            method: 'scrollToAnnotation'
            params: annotation.$$tag

    $scope.shouldShowThread = (container) ->
      if $scope.selectedAnnotations? and not container.parent.parent
        $scope.selectedAnnotations[container.message?.id]
      else
        true

    $scope.hasFocus = (annotation) ->
      annotation?.$$tag in ($scope.focusedAnnotations ? [])

angular.module('h')
.controller('AppController', AppController)
.controller('ViewerController', ViewerController)
.controller('AnnotationViewerController', AnnotationViewerController)
