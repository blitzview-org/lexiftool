--------------------------------------------------------------------------------
-- File:         lexiftool/DarwinCore.lua
-- Ported from:  lib/Image/ExifTool/DarwinCore.pm
--
-- Description:  Darwin Core XMP tags
--
-- Revisions:    2013-01-28 - P. Harvey Created
--               2025-03-09 - Herb forum17172 changes dwc.tdwg.org 2023
--
-- References:   1) http://rs.tdwg.org/dwc/index.htm
--               2) https://exiftool.org/forum/index.php/topic,4442.0/all.html
--
-- Port notes:   complete: every structure and the Main table in full. The
--               module is pure tag tables -- XMP.lua dispatches the 'dwc'
--               namespace into DarwinCore.Main.
--
--               The PrintConvInv of `eventTime` works on upstream's
--               $evalWarning, which is ExifTool.evalWarning here.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local str = perl.str

local DarwinCore = {}

local dateTimeInfo = {
    -- NOTE: Do NOT put "Groups" here because Groups hash must not be common!
    Writable = 'date',
    Shift = 'Time',
    PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    PrintConvInv = function(self, val) return self:InverseDateTime(val, nil, 1) end,
}

-- (upstream spreads %dateTimeInfo into a field hash with `%dateTimeInfo,
--  Groups => {...}`; this helper is that spread)
local function withDateTimeInfo(extra)
    local t = {}
    for k, v in pairs(dateTimeInfo) do t[k] = v end
    for k, v in pairs(extra or {}) do t[k] = v end
    return t
end

local materialSample = {
    STRUCT_NAME = 'DarwinCore MaterialSample',
    NAMESPACE = 'dwc',
    materialSampleID    = { },
}

local event = {
    STRUCT_NAME = 'DarwinCore Event',
    NAMESPACE = 'dwc',
    day                 = { Writable = 'integer', Groups = { [2] = 'Time' } },
    earliestDate        = withDateTimeInfo{ Groups = { [2] = 'Time' } },     -- dwc.tdwg.org removed 2023
    endDayOfYear        = { Writable = 'integer', Groups = { [2] = 'Time' } },
    eventDate           = withDateTimeInfo{ Groups = { [2] = 'Time' } },
    eventID             = { Avoid = 1, Notes = 'avoided in favor of XMP-iptcExt:EventID' },
    eventRemarks        = { Writable = 'lang-alt' },
    eventTime = {
        Groups = { [2] = 'Time' },
        Writable = 'string', -- (so we can format this ourself)
        Shift = 'Time',
        -- (allow date/time or just time value)
        ValueConv = function(_self, val) return require('lexiftool.XMP').ConvertXMPDate(val) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
        ValueConvInv = function(_self, val)
            return require('lexiftool.XMP').FormatXMPDate(val) or val
        end,
        PrintConvInv = function(self, val)
            local v = self:InverseDateTime(val, nil, 1)
            ExifTool.evalWarning = nil
            if v then return v end
            -- allow time-only values by adding dummy date (thanks Herb)
            v = self:InverseDateTime('2000:01:01 ' .. str(val), nil, 1)
            ExifTool.evalWarning = nil
            if v then
                local stripped = perl.subst(v, '.* ', '')  -- strip off dummy date
                if stripped ~= v then return stripped end
            end
            ExifTool.evalWarning = 'Invalid date/time or time-only value (use HH:MM:SS[.ss][+/-HH:MM|Z])'
            return nil
        end,
    },
    fieldNotes          = { },
    fieldNumber         = { },
    habitat             = { },
    latestDate          = withDateTimeInfo{ Groups = { [2] = 'Time' } },      -- dwc.tdwg.org removed 2023
    month               = { Writable = 'integer', Groups = { [2] = 'Time' } },
    parentEventID       = { },
    samplingEffort      = { },
    samplingProtocol    = { },
    sampleSizeValue     = { },
    sampleSizeUnit      = { },
    startDayOfYear      = { Writable = 'integer', Groups = { [2] = 'Time' } },
    verbatimEventDate   = { Groups = { [2] = 'Time' } },
    year                = { Writable = 'integer', Groups = { [2] = 'Time' } },
    eventType           = { },                                               -- dwc.tdwg.org added 2023
}

-- Darwin Core tags
DarwinCore.Main = {
    GROUPS    = { [0] = 'XMP', [1] = 'XMP-dwc', [2] = 'Other' },
    NAMESPACE = 'dwc',
    WRITABLE  = 'string',
    NOTES = [[
        Tags defined in the Darwin Core (dwc) XMP namespace.  See
        L<http://rs.tdwg.org/dwc/index.htm> for the official specification.
    ]],
    Event = {
        Name = 'DCEvent',  -- (avoid conflict with XMP-iptcExt:Event)
        FlatName = 'Event',
        Struct = event,
    },
    -- tweak a few of the flattened tag names
    EventEventDate    = { Name = 'EventDate',     Flat = 1 },
    EventEventID      = { Name = 'EventID',       Flat = 1 },
    EventEventRemarks = { Name = 'EventRemarks',  Flat = 1 },
    EventEventTime    = { Name = 'EventTime',     Flat = 1 },
    FossilSpecimen    = { Struct = materialSample },
    GeologicalContext = {
        FlatName = '', -- ('GeologicalContext' is too long)
        Struct = {
            STRUCT_NAME = 'DarwinCore GeologicalContext',
            NAMESPACE = 'dwc',
            bed                         = { },
            earliestAgeOrLowestStage    = { },
            earliestEonOrLowestEonothem = { },
            earliestEpochOrLowestSeries = { },
            earliestEraOrLowestErathem  = { },
            earliestPeriodOrLowestSystem= { },
            formation                   = { },
            geologicalContextID         = { },
            group                       = { },
            highestBiostratigraphicZone = { },
            latestAgeOrHighestStage     = { },
            latestEonOrHighestEonothem  = { },
            latestEpochOrHighestSeries  = { },
            latestEraOrHighestErathem   = { },
            latestPeriodOrHighestSystem = { },
            lithostratigraphicTerms     = { },
            lowestBiostratigraphicZone  = { },
            member                      = { },
        },
    },
    GeologicalContextBed        = { Name = 'GeologicalContextBed',        Flat = 1 },
    GeologicalContextFormation  = { Name = 'GeologicalContextFormation',  Flat = 1 },
    GeologicalContextGroup      = { Name = 'GeologicalContextGroup',      Flat = 1 },
    GeologicalContextMember     = { Name = 'GeologicalContextMember',     Flat = 1 },
    HumanObservation = { Struct = event },
    Identification = {
        FlatName = '', -- ('Identification' is redundant)
        Struct = {
            STRUCT_NAME = 'DarwinCore Identification',
            NAMESPACE = 'dwc',
            dateIdentified              = withDateTimeInfo{ Groups = { [2] = 'Time' } },
            identificationID            = { },
            identificationQualifier     = { },
            identificationReferences    = { },
            identificationRemarks       = { },
            identificationVerificationStatus = { },
            identifiedBy                = { },
            typeStatus                  = { },
            -- new, ref forum13707
            identifiedByID              = { },
            verbatimIdentification      = { },
        },
    },
    LivingSpecimen      = { Struct = materialSample },
    MachineObservation  = { Struct = event },
    MaterialSample      = { Struct = materialSample },
    MaterialSampleMaterialSampleID = { Name = 'MaterialSampleID', Flat = 1 },
    MeasurementOrFact = {
        FlatName = '', -- ('MeasurementOrFact' is redundant and too long)
        Struct = {
            STRUCT_NAME = 'DarwinCore MeasurementOrFact',
            NAMESPACE = 'dwc',
            measurementAccuracy         = { Format = 'real' },
            measurementDeterminedBy     = { },
            measurementDeterminedDate   = withDateTimeInfo{ Groups = { [2] = 'Time' } },
            measurementID               = { },
            measurementMethod           = { },
            measurementRemarks          = { },
            measurementType             = { },
            measurementUnit             = { },
            measurementValue            = { },
            parentMeasurementID         = { },          -- dwc.tdwg.org added 2023
        },
    },
    Occurrence = {
        Struct = {
            STRUCT_NAME = 'DarwinCore Occurrence',
            NAMESPACE = 'dwc',
            associatedMedia             = { },
            associatedOccurrences       = { },
            associatedReferences        = { },
            associatedSequences         = { },         -- dwc.tdwg.org removed 2023
            associatedTaxa              = { },
            behavior                    = { },
            catalogNumber               = { },
            disposition                 = { },         -- dwc.tdwg.org removed 2023
            establishmentMeans          = { },
            individualCount             = { },
            individualID                = { },         -- dwc.tdwg.org removed 2023
            lifeStage                   = { },
            occurrenceDetails           = { },
            occurrenceID                = { },         -- dwc.tdwg.org removed 2023
            occurrenceRemarks           = { },
            occurrenceStatus            = { },
            organismQuantity            = { },
            organismQuantityType        = { },
            otherCatalogNumbers         = { },
            preparations                = { },
            previousIdentifications     = { },         -- dwc.tdwg.org removed 2023
            recordedBy                  = { },         -- dwc.tdwg.org removed 2023
            recordNumber                = { },
            reproductiveCondition       = { },
            sex                         = { },
            -- new, ref forum13707
            degreeOfEstablishment       = { },
            georeferenceVerificationStatus = { },
            pathway                     = { },
            recordedByID                = { },
            caste                       = { },         -- dwc.tdwg.org added 2023
            vitality                    = { },         -- dwc.tdwg.org added 2023
        },
    },
    OccurrenceOccurrenceDetails = { Name = 'OccurrenceDetails', Flat = 1 },
    OccurrenceOccurrenceID      = { Name = 'OccurrenceID',      Flat = 1 },
    OccurrenceOccurrenceRemarks = { Name = 'OccurrenceRemarks', Flat = 1 },
    OccurrenceOccurrenceStatus  = { Name = 'OccurrenceStatus',  Flat = 1 },
    Organism = {
        Struct = {
            STRUCT_NAME = 'DarwinCore Organism',
            NAMESPACE = 'dwc',
            associatedOccurrences       = { },          -- dwc.tdwg.org removed 2023
            associatedOrganisms         = { },
            organismID                  = { },
            organismName                = { },
            organismRemarks             = { },
            organismScope               = { },
            previousIdentifications     = { },
        },
    },
    OrganismOrganismID      = { Name = 'OrganismID',      Flat = 1 },
    OrganismOrganismName    = { Name = 'OrganismName',    Flat = 1 },
    OrganismOrganismRemarks = { Name = 'OrganismRemarks', Flat = 1 },
    OrganismOrganismScope   = { Name = 'OrganismScope',   Flat = 1 },
    PreservedSpecimen       = { Struct = materialSample },
    Record = {
        Struct = {
            STRUCT_NAME = 'DarwinCore Record',
            NAMESPACE = 'dwc',
            basisOfRecord               = { },
            collectionCode              = { },
            collectionID                = { },
            dataGeneralizations         = { },
            datasetID                   = { },
            datasetName                 = { },
            dynamicProperties           = { },
            informationWithheld         = { },
            institutionCode             = { },
            institutionID               = { },
            ownerInstitutionCode        = { },
        },
    },
    ResourceRelationship = {
        FlatName = '', -- ('ResourceRelationship' is redundant and too long)
        Struct = {
            STRUCT_NAME = 'DarwinCore ResourceRelationship',
            NAMESPACE = 'dwc',
            relatedResourceID           = { },
            relationshipAccordingTo     = { },
            relationshipEstablishedDate = withDateTimeInfo{ Groups = { [2] = 'Time' } },
            relationshipOfResource      = { },
            relationshipRemarks         = { },
            resourceID                  = { },
            resourceRelationshipID      = { },
            relationshipOfResourceID    = { }, -- new, ref forum13707
        },
    },
    Taxon = {
        Struct = {
            STRUCT_NAME = 'DarwinCore Taxon',
            NAMESPACE = 'dwc',
            acceptedNameUsage           = { },
            acceptedNameUsageID         = { },
            class                       = { },
            family                      = { },
            genus                       = { },
            higherClassification        = { },
            infraspecificEpithet        = { },
            cultivarEpithet             = { }, -- new, ref forum13707
            kingdom                     = { },
            nameAccordingTo             = { },
            nameAccordingToID           = { },
            namePublishedIn             = { },
            namePublishedInID           = { },
            namePublishedInYear         = { },
            nomenclaturalCode           = { },
            nomenclaturalStatus         = { },
            order                       = { },
            originalNameUsage           = { },
            originalNameUsageID         = { },
            parentNameUsage             = { },
            parentNameUsageID           = { },
            phylum                      = { },
            scientificName              = { },
            scientificNameAuthorship    = { },
            scientificNameID            = { },
            specificEpithet             = { },
            subgenus                    = { },
            taxonConceptID              = { },
            taxonID                     = { },
            taxonRank                   = { },
            taxonRemarks                = { },
            taxonomicStatus             = { },
            verbatimTaxonRank           = { },
            vernacularName              = { Writable = 'lang-alt' },
            superFamily                 = { },     -- dwc.tdwg.org added 2023
            subFamily                   = { },     -- dwc.tdwg.org added 2023
            tribe                       = { },     -- dwc.tdwg.org added 2023
            subTribe                    = { },     -- dwc.tdwg.org added 2023
            genericName                 = { },     -- dwc.tdwg.org added 2023
            infragenericEpithet         = { },     -- dwc.tdwg.org added 2023
        },
    },
    TaxonTaxonConceptID = { Name = 'TaxonConceptID',  Flat = 1 },
    TaxonTaxonID        = { Name = 'TaxonID',         Flat = 1 },
    TaxonTaxonRank      = { Name = 'TaxonRank',       Flat = 1 },
    TaxonTaxonRemarks   = { Name = 'TaxonRemarks',    Flat = 1 },
    dctermsLocation = {
        Name = 'DCTermsLocation',
        Groups = { [2] = 'Location' },
        FlatName = 'DC', -- ('dctermsLocation' is too long)
        Struct = {
            STRUCT_NAME = 'DarwinCore DCTermsLocation',
            NAMESPACE = 'dwc',
            continent                   = { },
            coordinatePrecision         = { },
            coordinateUncertaintyInMeters = { },
            country                     = { },
            countryCode                 = { },
            county                      = { },
            decimalLatitude             = { },
            decimalLongitude            = { },
            footprintSpatialFit         = { },
            footprintSRS                = { },
            footprintWKT                = { },
            geodeticDatum               = { },
            georeferencedBy             = { },
            georeferencedDate           = { },
            georeferenceProtocol        = { },
            georeferenceRemarks         = { },
            georeferenceSources         = { },
            georeferenceVerificationStatus = { },      -- dwc.tdwg.org removed 2023
            higherGeography             = { },
            higherGeographyID           = { },
            island                      = { },
            islandGroup                 = { },
            locality                    = { },
            locationAccordingTo         = { },
            locationID                  = { },
            locationRemarks             = { },
            maximumDepthInMeters        = { },
            maximumDistanceAboveSurfaceInMeters = { },
            maximumElevationInMeters    = { },
            minimumDepthInMeters        = { },
            minimumDistanceAboveSurfaceInMeters = { },
            minimumElevationInMeters    = { },
            municipality                = { },
            pointRadiusSpatialFit       = { },
            stateProvince               = { },
            verbatimCoordinates         = { },
            verbatimCoordinateSystem    = { },
            verbatimDepth               = { },
            verbatimElevation           = { },
            verbatimLatitude            = { },
            verbatimLocality            = { },
            verbatimLongitude           = { },
            verbatimSRS                 = { },
            waterBody                   = { },
            -- new, ref forum13707
            verticalDatum               = { },
        },
    },
}

return DarwinCore
